#!/usr/bin/env bash
set -euo pipefail

OUTPUT=${1:-"$HOME/R11T-backups/$(date -u +%Y%m%dT%H%M%SZ)"}
mkdir -p "$OUTPUT"
chmod 0700 "$OUTPUT"
[[ -z $(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
	echo "ERROR: backup directory is not empty: $OUTPUT" >&2
	exit 1
}

adb get-state >/dev/null
MAP=$OUTPUT/partition-map.tsv
adb shell 'su 0 sh -c '\''for link in /dev/block/by-name/*; do name=${link##*/}; dev=$(readlink -f "$link"); bytes=$(blockdev --getsize64 "$dev"); printf "%s\t%s\t%s\n" "$name" "$dev" "$bytes"; done'\''' \
	| tr -d '\r' | LC_ALL=C sort > "$MAP"

declare -A saved_path saved_hash
printf 'name\tdevice\tbytes\tsha256\tfile\n' > "$OUTPUT/SHA256SUMS.tsv"
while IFS=$'\t' read -r name device bytes; do
	case "$name" in system|userdata|cache) continue ;; esac
	[[ $name =~ ^[A-Za-z0-9._-]+$ && $bytes =~ ^[0-9]+$ ]] || {
		echo "ERROR: invalid partition map entry: $name $device $bytes" >&2
		exit 1
	}
	(( bytes <= 2147483648 )) || {
		echo "ERROR: refusing unexpectedly large private partition $name ($bytes bytes)" >&2
		exit 1
	}
	out=$OUTPUT/$name.img
	if [[ -n ${saved_path[$device]:-} ]]; then
		ln "${saved_path[$device]}" "$out"
		hash=${saved_hash[$device]}
	else
		echo "Backing up $name ($bytes bytes)"
		adb exec-out su 0 dd if="$device" bs=4194304 2>/dev/null > "$out"
		[[ $(stat -c %s "$out") == "$bytes" ]] || {
			echo "ERROR: short backup for $name" >&2
			exit 1
		}
		source_hash=$(adb shell su 0 sha256sum "$device" | tr -d '\r' | cut -d ' ' -f 1)
		hash=$(sha256sum "$out" | cut -d ' ' -f 1)
		[[ $hash == "$source_hash" ]] || {
			echo "ERROR: source/readback hash mismatch for $name" >&2
			exit 1
		}
		saved_path[$device]=$out
		saved_hash[$device]=$hash
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$name" "$device" "$bytes" "$hash" "$(basename "$out")" \
		>> "$OUTPUT/SHA256SUMS.tsv"
done < "$MAP"

IFS=$'\t' read -r _ first_device _ < "$MAP"
case "$first_device" in
	/dev/block/mmcblk*p*) DISK=${first_device%p*} ;;
	/dev/mmcblk*p*) DISK=${first_device%p*} ;;
	*) echo "ERROR: cannot derive eMMC device from $first_device" >&2; exit 1 ;;
esac
sectors=$(adb shell su 0 blockdev --getsz "$DISK" | tr -d '\r')
[[ $sectors =~ ^[0-9]+$ && $sectors -gt 67 ]] || {
	echo 'ERROR: invalid eMMC sector count' >&2
	exit 1
}
adb exec-out su 0 dd if="$DISK" bs=512 count=34 2>/dev/null \
	> "$OUTPUT/gpt-primary-34sectors.img"
adb exec-out su 0 dd if="$DISK" bs=512 skip=$((sectors - 33)) count=33 2>/dev/null \
	> "$OUTPUT/gpt-backup-33sectors.img"
sha256sum "$OUTPUT"/gpt-*.img > "$OUTPUT/GPT-SHA256SUMS"
sync

echo "Backup complete: $OUTPUT"
du -sh "$OUTPUT"
