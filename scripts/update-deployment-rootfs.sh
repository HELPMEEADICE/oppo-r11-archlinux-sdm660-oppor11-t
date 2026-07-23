#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${1:-}
BOOT_IMAGE=${2:-$ROOT/linux/build/boot-r11t-arch.img}
MOUNT_ROOT=/tmp/r11t-update-root
LOOP=

usage() {
	echo "usage: $0 ROOTFS_IMAGE [BOOT_IMAGE]" >&2
	exit 2
}

[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ -n $IMAGE && -f $IMAGE && -f $BOOT_IMAGE ]] || usage
[[ $(stat -c %s "$IMAGE") -eq $((8 * 1024 * 1024 * 1024)) ]] || {
	echo 'ERROR: deployment rootfs must be exactly 8 GiB' >&2
	exit 1
}
[[ $(dd if="$BOOT_IMAGE" bs=8 count=1 status=none) == 'ANDROID!' ]] || {
	echo 'ERROR: boot image has no Android boot magic' >&2
	exit 1
}

cleanup() {
	set +e
	mountpoint -q "$MOUNT_ROOT/.snapshots" && umount "$MOUNT_ROOT/.snapshots"
	mountpoint -q "$MOUNT_ROOT" && umount "$MOUNT_ROOT"
	[[ -n $LOOP ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

mkdir -p "$MOUNT_ROOT"
LOOP=$(losetup --find --show "$IMAGE")
mount -o subvol=@,compress=zstd:3,noatime,space_cache=v2 "$LOOP" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT/.snapshots"
mount -o subvol=@snapshots,compress=zstd:3,noatime,space_cache=v2 \
	"$LOOP" "$MOUNT_ROOT/.snapshots"

cp -a --no-preserve=ownership "$ROOT/archlinux/rootfs-overlay/." "$MOUNT_ROOT/"
grep -qxF DisableSandbox "$MOUNT_ROOT/etc/pacman.conf" ||
	sed -i '/^\[options\]$/a DisableSandbox' "$MOUNT_ROOT/etc/pacman.conf"
install -m 0755 "$ROOT/linux/build/initramfs-root/bin/bt-hci-test" \
	"$MOUNT_ROOT/usr/lib/r11t/bt-hci-test"
install -m 0644 "$BOOT_IMAGE" "$MOUNT_ROOT/usr/lib/r11t/boot-r11t-arch.img"

if [[ ${R11T_SKIP_MODULE_INSTALL:-0} != 1 ]]; then
	make -C "$ROOT/linux" O=build ARCH=arm64 INSTALL_MOD_PATH="$MOUNT_ROOT" \
		INSTALL_MOD_STRIP=1 modules_install
fi
set -- "$MOUNT_ROOT"/lib/modules/*
[[ $# -eq 1 && -d $1 ]] || {
	echo 'ERROR: expected exactly one installed kernel module version' >&2
	exit 1
}
kernel_release=${1##*/}
rm -f "$1/build" "$1/source"
depmod -b "$MOUNT_ROOT" "$kernel_release"

if [[ -n ${R11T_PASSWORD:-} ]]; then
	printf 'root:%s\nalarm:%s\n' "$R11T_PASSWORD" "$R11T_PASSWORD" | \
		chroot "$MOUNT_ROOT" /usr/sbin/chpasswd
fi

for unit in NetworkManager.service bluetooth.service sshd.service \
	r11t-usb-gadget.service serial-getty@ttyGS0.service fstrim.timer \
	r11t-grow-root.service r11t-hardware.target sddm.service; do
	systemctl --root="$MOUNT_ROOT" enable "$unit" >/dev/null
done

if btrfs subvolume show "$MOUNT_ROOT/.snapshots/1-installation" >/dev/null 2>&1; then
	btrfs property set -ts "$MOUNT_ROOT/.snapshots/1-installation" ro false
	btrfs subvolume delete "$MOUNT_ROOT/.snapshots/1-installation"
fi
btrfs subvolume snapshot -r "$MOUNT_ROOT" "$MOUNT_ROOT/.snapshots/1-installation"
sync

umount "$MOUNT_ROOT/.snapshots"
umount "$MOUNT_ROOT"
losetup -d "$LOOP"
LOOP=
btrfs check --readonly "$IMAGE"
sha256sum "$IMAGE" "$BOOT_IMAGE"
