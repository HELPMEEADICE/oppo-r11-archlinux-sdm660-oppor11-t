#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LINUX="$ROOT/linux"
BUILD="$LINUX/build"
WORK="$BUILD/arch-initramfs-root"
BUSYBOX=${BUSYBOX:-$BUILD/initramfs-root/bin/busybox}
RAMDISK="$BUILD/r11t-arch-initramfs.cpio.gz"
KERNEL_DTB="$BUILD/arch/arm64/boot/Image.gz-dtb"
OUTPUT=${OUTPUT:-$BUILD/boot-r11t-arch.img}

[ -x "$BUSYBOX" ] || {
	echo "ERROR: static AArch64 busybox not found at $BUSYBOX" >&2
	echo "Run scripts/build-diag-image.sh first or set BUSYBOX=." >&2
	exit 1
}

make -C "$LINUX" O=build ARCH=arm64 LLVM=1 -j"$(nproc)" \
	Image.gz qcom/sdm660-oppo-r11t.dtb

rm -rf "$WORK"
mkdir -p "$WORK"/{bin,dev,proc,sys,newroot}
install -m 0755 "$BUSYBOX" "$WORK/bin/busybox"
install -m 0755 "$ROOT/initramfs/init.arch" "$WORK/init"
(
	cd "$WORK"
	find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > "$RAMDISK"

ramdisk_size=$(stat -c %s "$RAMDISK")
ramdisk_limit=$((0x85600000 - 0x83000000))
if (( ramdisk_size >= ramdisk_limit )); then
	printf 'ERROR: production ramdisk crosses 0x85600000: %d bytes\n' \
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
	--cmdline 'console=tty0 console=ttyMSM0,115200n8 earlycon=msm_serial_dm,0xc170000 loglevel=7 panic=10 root=PARTLABEL=userdata rootfstype=btrfs rootflags=subvol=@,compress=zstd:3,noatime,space_cache=v2 rootwait rw rdinit=/init' \
	-o "$OUTPUT"

image_size=$(stat -c %s "$OUTPUT")
(( image_size <= 64 * 1024 * 1024 )) || {
	echo "ERROR: production image is larger than boot" >&2
	exit 1
}

printf 'Production ramdisk end: 0x%x (%d bytes free)\n' \
	$((0x83000000 + ramdisk_size)) $((ramdisk_limit - ramdisk_size))
sha256sum "$OUTPUT"
unpack_bootimg --boot_img "$OUTPUT" --format=info
