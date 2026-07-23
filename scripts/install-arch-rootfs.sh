#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LINUX="$ROOT/linux"
BUILD="$LINUX/build"
OVERLAY="$ROOT/archlinux/rootfs-overlay"
PACKAGES_FILE="$ROOT/archlinux/packages.txt"
EXPECTED_SIZE=56933465600
MOUNT_ROOT=${R11T_MOUNT_ROOT:-/tmp/opencode/r11t-arch-root}
DEVICE=
CONFIRM=0

usage() {
	echo "usage: $0 --device /dev/<userdata-lun> --confirm" >&2
	exit 2
}

while (($#)); do
	case "$1" in
	--device) DEVICE=${2:-}; shift 2 ;;
	--confirm) CONFIRM=1; shift ;;
	*) usage ;;
	esac
done

[ "$EUID" -eq 0 ] || { echo 'ERROR: run as root' >&2; exit 1; }
[ "$CONFIRM" -eq 1 ] || { echo 'ERROR: --confirm is required' >&2; exit 1; }
[ -b "$DEVICE" ] || { echo "ERROR: not a block device: $DEVICE" >&2; exit 1; }
[ "$(blockdev --getsize64 "$DEVICE")" = "$EXPECTED_SIZE" ] || {
	echo "ERROR: $DEVICE does not have the exact R11T userdata size" >&2
	exit 1
}
mountpoint -q "$MOUNT_ROOT" && {
	echo "ERROR: $MOUNT_ROOT is already mounted" >&2
	exit 1
}

cleanup() {
	set +e
	for path in \
		"$MOUNT_ROOT/var/cache/pacman/pkg" \
		"$MOUNT_ROOT/var/log" \
		"$MOUNT_ROOT/.snapshots" \
		"$MOUNT_ROOT/home" \
		"$MOUNT_ROOT"; do
		mountpoint -q "$path" && umount "$path"
	done
}
trap cleanup EXIT

echo "Formatting $DEVICE as the R11T Arch Btrfs root"
wipefs --all "$DEVICE"
mkfs.btrfs --force --label R11T_ROOT "$DEVICE"
mkdir -p "$MOUNT_ROOT"
mount -o noatime,compress=zstd:3,space_cache=v2 "$DEVICE" "$MOUNT_ROOT"
for subvol in @ @home @snapshots @var_log @pacman_cache; do
	btrfs subvolume create "$MOUNT_ROOT/$subvol"
done
umount "$MOUNT_ROOT"

mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@ \
	"$DEVICE" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT"/{home,.snapshots,var/log,var/cache/pacman/pkg}
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@home \
	"$DEVICE" "$MOUNT_ROOT/home"
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@snapshots \
	"$DEVICE" "$MOUNT_ROOT/.snapshots"
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@var_log \
	"$DEVICE" "$MOUNT_ROOT/var/log"
mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@pacman_cache \
	"$DEVICE" "$MOUNT_ROOT/var/cache/pacman/pkg"

mapfile -t packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
	"$PACKAGES_FILE")
pacstrap "$MOUNT_ROOT" "${packages[@]}"

cp -a --no-preserve=ownership "$OVERLAY/." "$MOUNT_ROOT/"
grep -qxF DisableSandbox "$MOUNT_ROOT/etc/pacman.conf" ||
	sed -i '/^\[options\]$/a DisableSandbox' "$MOUNT_ROOT/etc/pacman.conf"
find "$MOUNT_ROOT/usr/lib/r11t" -type f -exec chmod 0755 {} +
install -d -m 0755 "$MOUNT_ROOT"/{mnt/vendor,mnt/modem,mnt/persist,srv/r11t-rescue,var/lib/r11t-state}

make -C "$LINUX" O=build ARCH=arm64 LLVM=1 \
	modules_install INSTALL_MOD_PATH="$MOUNT_ROOT"
kernel_release=$(make -C "$LINUX" O=build ARCH=arm64 LLVM=1 -s kernelrelease)
depmod -b "$MOUNT_ROOT" "$kernel_release"

install -d -m 0755 "$MOUNT_ROOT/usr/lib/r11t" "$MOUNT_ROOT/usr/lib/firmware"
install -m 0644 "$BUILD/arch/arm64/boot/dts/qcom/sdm660-oppo-r11t.dtb" \
	"$MOUNT_ROOT/usr/lib/r11t/"
install -m 0644 "$BUILD/.config" \
	"$MOUNT_ROOT/usr/lib/r11t/config-$kernel_release"

if [ -d "$BUILD/initramfs-root/lib/firmware" ]; then
	cp -a --no-preserve=ownership "$BUILD/initramfs-root/lib/firmware/." \
		"$MOUNT_ROOT/usr/lib/firmware/"
fi
for tool in rmtfs tqftpserv diag-router wifi-mac bt-hci-test; do
	if [ -x "$BUILD/initramfs-root/bin/$tool" ]; then
		install -m 0755 "$BUILD/initramfs-root/bin/$tool" \
			"$MOUNT_ROOT/usr/lib/r11t/$tool"
	fi
done

arch-chroot "$MOUNT_ROOT" locale-gen
arch-chroot "$MOUNT_ROOT" useradd -m -G wheel,audio,video,input,network -s /bin/bash alarm
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$MOUNT_ROOT/etc/sudoers.d/10-wheel"
chmod 0440 "$MOUNT_ROOT/etc/sudoers.d/10-wheel"

for unit in NetworkManager.service bluetooth.service sshd.service \
	r11t-usb-gadget.service serial-getty@ttyGS0.service fstrim.timer \
	r11t-grow-root.service r11t-hardware.target sddm.service; do
	arch-chroot "$MOUNT_ROOT" systemctl enable "$unit"
done

if [ "${R11T_SKIP_PASSWORDS:-0}" != 1 ]; then
	echo 'Set the root password:'
	arch-chroot "$MOUNT_ROOT" passwd root
	echo 'Set the alarm user password:'
	arch-chroot "$MOUNT_ROOT" passwd alarm
else
	arch-chroot "$MOUNT_ROOT" passwd -l root
	arch-chroot "$MOUNT_ROOT" passwd -l alarm
	echo 'WARNING: root and alarm accounts are locked.' >&2
fi

btrfs subvolume snapshot -r "$MOUNT_ROOT" \
	"$MOUNT_ROOT/.snapshots/1-installation"
btrfs filesystem sync "$MOUNT_ROOT"
btrfs filesystem usage "$MOUNT_ROOT"
echo 'Arch root filesystem installation complete.'
