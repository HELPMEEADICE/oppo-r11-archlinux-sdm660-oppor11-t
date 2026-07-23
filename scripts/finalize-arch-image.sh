#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=
OUTPUT=
CONFIRM=0
SOURCE_SIZE=56933465600
OUTPUT_SIZE=8589934592
MOUNT_ROOT=${R11T_FINALIZE_MOUNT:-/tmp/opencode/r11t-finalize}

while (($#)); do
	case "$1" in
	--source) SOURCE=${2:-}; shift 2 ;;
	--output) OUTPUT=${2:-}; shift 2 ;;
	--confirm) CONFIRM=1; shift ;;
	*) echo "usage: $0 --source 53g.img --output 8g.img --confirm" >&2; exit 2 ;;
	esac
done

[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ $CONFIRM -eq 1 ]] || { echo 'ERROR: --confirm is required' >&2; exit 1; }
[[ -f $SOURCE ]] || { echo 'ERROR: source image not found' >&2; exit 1; }
[[ $(stat -c %s "$SOURCE") == "$SOURCE_SIZE" ]] || {
	echo 'ERROR: source image does not have the R11T userdata size' >&2
	exit 1
}
[[ ! -e $OUTPUT ]] || { echo 'ERROR: output already exists' >&2; exit 1; }
[[ -f $ROOT/linux/build/boot-r11t-arch.img ]] || {
	echo 'ERROR: build the production boot image first' >&2
	exit 1
}

mkdir -p "$MOUNT_ROOT"
cp --reflink=auto --sparse=always "$SOURCE" "$OUTPUT"
LOOP=$(losetup --find --show "$OUTPUT")
mounted_root=0
mounted_snapshots=0
cleanup() {
	if (( mounted_snapshots )); then umount "$MOUNT_ROOT/.snapshots" || true; fi
	if (( mounted_root )); then umount "$MOUNT_ROOT" || true; fi
	losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

mount -o subvol=@,compress=zstd:3,noatime,space_cache=v2 "$LOOP" "$MOUNT_ROOT"
mounted_root=1
mount -o subvol=@snapshots,compress=zstd:3,noatime,space_cache=v2 \
	"$LOOP" "$MOUNT_ROOT/.snapshots"
mounted_snapshots=1

cp -a --no-preserve=ownership "$ROOT/archlinux/rootfs-overlay/." "$MOUNT_ROOT/"
grep -qxF DisableSandbox "$MOUNT_ROOT/etc/pacman.conf" ||
	sed -i '/^\[options\]$/a DisableSandbox' "$MOUNT_ROOT/etc/pacman.conf"
find "$MOUNT_ROOT/usr/lib/r11t" -type f -exec chmod 0755 {} +
install -m 0755 "$ROOT/linux/build/initramfs-root/bin/bt-hci-test" \
	"$MOUNT_ROOT/usr/lib/r11t/bt-hci-test"
install -m 0644 "$ROOT/linux/build/boot-r11t-arch.img" \
	"$MOUNT_ROOT/usr/lib/r11t/boot-r11t-arch.img"

for unit in NetworkManager.service bluetooth.service sshd.service \
	r11t-usb-gadget.service serial-getty@ttyGS0.service fstrim.timer \
	r11t-grow-root.service r11t-hardware.target sddm.service; do
	systemctl --root="$MOUNT_ROOT" enable "$unit"
done
systemd-analyze verify --man=no --generators=no --root="$MOUNT_ROOT" \
	r11t-grow-root.service r11t-hardware.target sddm.service \
	NetworkManager.service bluetooth.service

if [[ -d $MOUNT_ROOT/.snapshots/1-installation ]]; then
	btrfs subvolume delete "$MOUNT_ROOT/.snapshots/1-installation"
fi
btrfs subvolume snapshot -r "$MOUNT_ROOT" \
	"$MOUNT_ROOT/.snapshots/1-installation"
sync

umount "$MOUNT_ROOT/.snapshots"
mounted_snapshots=0
btrfs filesystem resize "$OUTPUT_SIZE" "$MOUNT_ROOT"
btrfs filesystem sync "$MOUNT_ROOT"
umount "$MOUNT_ROOT"
mounted_root=0
losetup -d "$LOOP"
trap - EXIT

truncate -s "$OUTPUT_SIZE" "$OUTPUT"
LOOP=$(losetup --find --show --read-only "$OUTPUT")
trap 'losetup -d "$LOOP" 2>/dev/null || true' EXIT
btrfs check --readonly "$LOOP"
losetup -d "$LOOP"
trap - EXIT

echo "Final image: $OUTPUT"
stat -c 'size=%s allocated_blocks=%b' "$OUTPUT"
sha256sum "$OUTPUT"
