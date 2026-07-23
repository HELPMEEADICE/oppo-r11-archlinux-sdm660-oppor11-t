#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LINUX="$ROOT/linux"
BUILD="$LINUX/build"
IR="$BUILD/initramfs-root"
INIT="$ROOT/initramfs/init.arch-installer"
RAMDISK="$BUILD/r11t-installer-initramfs.cpio.gz"
KERNEL_DTB="$BUILD/arch/arm64/boot/Image.gz-dtb"
CMDLINE='console=tty0 console=ttyMSM0,115200n8 earlycon=msm_serial_dm,0xc170000 loglevel=7 panic=10 root=/dev/ram0 rw rdinit=/init'
TARGET=system
STORAGE_WRITE=0

while (($#)); do
	case "$1" in
	--target)
		TARGET=${2:-}
		shift 2
		;;
	--write)
		STORAGE_WRITE=1
		shift
		;;
	*)
		echo "usage: $0 [--target system|userdata|all] [--write]" >&2
		exit 2
		;;
	esac
done
case "$TARGET" in
	system|userdata|all) ;;
	*) echo 'invalid target' >&2; exit 2 ;;
esac

MODE=test
CMDLINE="$CMDLINE r11t.install_target=$TARGET"
if (( STORAGE_WRITE )); then
	MODE=write
	CMDLINE="$CMDLINE r11t.storage_write=1"
fi
OUTPUT="$BUILD/recovery-r11t-installer-ecm-$TARGET-$MODE.img"

"$ROOT/scripts/build-diag-image.sh"

install -m 0755 "$INIT" "$IR/init"
install -m 0755 "$ROOT/initramfs/receive-arch-image" "$IR/bin/receive_arch_image"
install -m 0755 "$ROOT/initramfs/receive-arch-boot" "$IR/bin/receive_arch_boot"
install -m 0755 /usr/bin/zstd "$IR/bin/zstd"
install -m 0755 /usr/lib/ld-linux-aarch64.so.1 "$IR/lib/ld-linux-aarch64.so.1"
for library in libzstd.so.1 libz.so.1 liblzma.so.5 liblz4.so.1 libc.so.6; do
	cp -L "/usr/lib/$library" "$IR/lib/$library"
done
(
	cd "$IR"
	find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > "$RAMDISK"

ramdisk_size=$(stat -c %s "$RAMDISK")
ramdisk_limit=$((0x85600000 - 0x83000000))
if (( ramdisk_size >= ramdisk_limit )); then
	printf 'ERROR: installer ramdisk crosses 0x85600000: %d bytes\n' \
		"$ramdisk_size" >&2
	exit 1
fi

cp "$BUILD/arch/arm64/boot/Image.gz" "$KERNEL_DTB"
dd if="$BUILD/arch/arm64/boot/dts/qcom/sdm660-oppo-r11t.dtb" \
	of="$KERNEL_DTB" oflag=append conv=notrunc status=none

mkbootimg \
	--kernel "$KERNEL_DTB" \
	--ramdisk "$RAMDISK" \
	--pagesize 4096 \
	--base 0x80000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x03000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x00000100 \
	--header_version 1 \
	--os_version 9.0.0 \
	--os_patch_level 2019-09 \
	--cmdline "$CMDLINE" \
	-o "$OUTPUT"

image_size=$(stat -c %s "$OUTPUT")
(( image_size <= 64 * 1024 * 1024 )) || {
	echo "ERROR: installer image is larger than recovery" >&2
	exit 1
}

printf 'Installer ramdisk end: 0x%x (%d bytes free)\n' \
	$((0x83000000 + ramdisk_size)) $((ramdisk_limit - ramdisk_size))
sha256sum "$OUTPUT"
unpack_bootimg --boot_img "$OUTPUT" --format=info
