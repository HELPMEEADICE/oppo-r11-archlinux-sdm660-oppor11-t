#!/usr/bin/env bash
set -euo pipefail

EXPECTED_SIZE=56933465600
MOUNT_ROOT=${R11T_ROLLBACK_MOUNT:-/tmp/opencode/r11t-rollback}
DEVICE=
SNAPSHOT=
CONFIRM=0

usage() {
	echo "usage: $0 --device /dev/<userdata-lun> --snapshot NAME --confirm" >&2
	exit 2
}

while (($#)); do
	case "$1" in
	--device) DEVICE=${2:-}; shift 2 ;;
	--snapshot) SNAPSHOT=${2:-}; shift 2 ;;
	--confirm) CONFIRM=1; shift ;;
	*) usage ;;
	esac
done

[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ $CONFIRM -eq 1 ]] || { echo 'ERROR: --confirm is required' >&2; exit 1; }
[[ -b $DEVICE ]] || { echo "ERROR: not a block device: $DEVICE" >&2; exit 1; }
[[ $(blockdev --getsize64 "$DEVICE") == "$EXPECTED_SIZE" ]] || {
	echo 'ERROR: device does not have the exact R11T userdata size' >&2
	exit 1
}
[[ $SNAPSHOT =~ ^[A-Za-z0-9._-]+$ ]] || {
	echo 'ERROR: invalid snapshot name' >&2
	exit 1
}
mountpoint -q "$MOUNT_ROOT" && { echo 'ERROR: rollback mount is busy' >&2; exit 1; }

mkdir -p "$MOUNT_ROOT"
mount -o noatime,compress=zstd:3,space_cache=v2 "$DEVICE" "$MOUNT_ROOT"
trap 'mountpoint -q "$MOUNT_ROOT" && umount "$MOUNT_ROOT"' EXIT

source="$MOUNT_ROOT/@snapshots/$SNAPSHOT"
[[ -d $source ]] || { echo "ERROR: snapshot not found: $SNAPSHOT" >&2; exit 1; }
[[ -d $MOUNT_ROOT/@ ]] || { echo 'ERROR: current @ subvolume is missing' >&2; exit 1; }
matching_boot="$source/usr/lib/r11t/boot-r11t-arch.img"
[[ -f $matching_boot ]] || {
	echo 'ERROR: snapshot has no matching boot image' >&2
	exit 1
}
[[ $(dd if="$matching_boot" bs=8 count=1 status=none) == 'ANDROID!' ]] || {
	echo 'ERROR: matching boot image has no Android boot header' >&2
	exit 1
}
matching_boot_hash=$(sha256sum "$matching_boot" | cut -d' ' -f1)

failed="@failed-$(date -u +%Y%m%dT%H%M%SZ)"
mv "$MOUNT_ROOT/@" "$MOUNT_ROOT/$failed"
if ! btrfs subvolume snapshot "$source" "$MOUNT_ROOT/@"; then
	mv "$MOUNT_ROOT/$failed" "$MOUNT_ROOT/@"
	exit 1
fi
btrfs filesystem sync "$MOUNT_ROOT"
echo "Restored root snapshot $SNAPSHOT"
echo "Previous root retained as $failed"
echo "Matching boot image: $matching_boot"
echo "Matching boot SHA-256: $matching_boot_hash"
echo 'Write this exact image with receive_arch_boot before rebooting.'
