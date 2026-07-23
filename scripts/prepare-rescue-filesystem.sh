#!/usr/bin/env bash
set -euo pipefail

EXPECTED_SIZE=3481272320
MOUNT_ROOT=${R11T_RESCUE_MOUNT:-/tmp/opencode/r11t-rescue}
DEVICE=
CONFIRM=0
ROOTFS_IMAGE=
BOOT_IMAGE=
RECOVERY_IMAGE=
ROOTFS_MANIFEST_ONLY=0

usage() {
	echo "usage: $0 --device BLOCK --rootfs-image FILE [--rootfs-manifest-only] --boot-image FILE --recovery-image FILE --confirm" >&2
	exit 2
}

while (($#)); do
	case "$1" in
	--device) DEVICE=${2:-}; shift 2 ;;
	--rootfs-image) ROOTFS_IMAGE=${2:-}; shift 2 ;;
	--rootfs-manifest-only) ROOTFS_MANIFEST_ONLY=1; shift ;;
	--boot-image) BOOT_IMAGE=${2:-}; shift 2 ;;
	--recovery-image) RECOVERY_IMAGE=${2:-}; shift 2 ;;
	--confirm) CONFIRM=1; shift ;;
	*) usage ;;
	esac
done

[ "$EUID" -eq 0 ] || { echo 'ERROR: run as root' >&2; exit 1; }
[ "$CONFIRM" -eq 1 ] || { echo 'ERROR: --confirm is required' >&2; exit 1; }
[ -b "$DEVICE" ] || { echo "ERROR: not a block device: $DEVICE" >&2; exit 1; }
[ "$(blockdev --getsize64 "$DEVICE")" = "$EXPECTED_SIZE" ] || {
	echo "ERROR: $DEVICE does not have the exact R11T system size" >&2
	exit 1
}
for artifact in "$ROOTFS_IMAGE" "$BOOT_IMAGE" "$RECOVERY_IMAGE"; do
	[ -f "$artifact" ] || { echo "ERROR: artifact not found: $artifact" >&2; exit 1; }
done
mountpoint -q "$MOUNT_ROOT" && {
	echo "ERROR: $MOUNT_ROOT is already mounted" >&2
	exit 1
}

trap 'mountpoint -q "$MOUNT_ROOT" && umount "$MOUNT_ROOT"' EXIT
wipefs --all "$DEVICE"
mkfs.btrfs --force --label R11T_RESCUE "$DEVICE"
mkdir -p "$MOUNT_ROOT"
mount -o noatime,compress=zstd:3,space_cache=v2 "$DEVICE" "$MOUNT_ROOT"
for subvol in @installer @kernels @recovery @archive; do
	btrfs subvolume create "$MOUNT_ROOT/$subvol"
done

mkdir -p "$MOUNT_ROOT/@installer/rootfs" \
	"$MOUNT_ROOT/@kernels" "$MOUNT_ROOT/@recovery"
install -m 0644 "$BOOT_IMAGE" "$MOUNT_ROOT/@kernels/"
install -m 0644 "$RECOVERY_IMAGE" "$MOUNT_ROOT/@recovery/"
if [ "$ROOTFS_MANIFEST_ONLY" -eq 0 ]; then
	install -m 0644 "$ROOTFS_IMAGE" "$MOUNT_ROOT/@installer/rootfs/"
fi
{
	printf 'file=%s\n' "$(basename "$ROOTFS_IMAGE")"
	printf 'size=%s\n' "$(stat -c %s "$ROOTFS_IMAGE")"
	printf 'sha256=%s\n' "$(sha256sum "$ROOTFS_IMAGE" | cut -d ' ' -f 1)"
	printf 'payload_stored=%s\n' "$(( 1 - ROOTFS_MANIFEST_ONLY ))"
} > "$MOUNT_ROOT/@installer/rootfs/r11t-arch-rootfs.manifest"
for artifact in \
	"$MOUNT_ROOT/@kernels/$(basename "$BOOT_IMAGE")" \
	"$MOUNT_ROOT/@recovery/$(basename "$RECOVERY_IMAGE")"; do
	sha256sum "$artifact" > "$artifact.sha256"
done
printf '%s\n' \
	'OPPO R11T offline installation and recovery filesystem.' \
	'Do not store device calibration data in public repositories.' \
	> "$MOUNT_ROOT/@recovery/README"
btrfs subvolume snapshot -r "$MOUNT_ROOT/@recovery" \
	"$MOUNT_ROOT/@archive/recovery-initial"
btrfs filesystem sync "$MOUNT_ROOT"
available=$(( $(stat -f -c %a "$MOUNT_ROOT") * $(stat -f -c %S "$MOUNT_ROOT") ))
minimum_free=$(( EXPECTED_SIZE * 15 / 100 ))
[ "$available" -ge "$minimum_free" ] || {
	echo "ERROR: rescue free space $available is below 15% reserve $minimum_free" >&2
	exit 1
}
btrfs filesystem usage "$MOUNT_ROOT"
echo "Rescue filesystem preparation complete; available=$available bytes."
