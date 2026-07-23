#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LINUX="$ROOT/linux"
BUILD=${BUILD:-$LINUX/build-gcc}
BUSYBOX=${BUSYBOX:-$LINUX/build/initramfs-root/bin/busybox}
KERNEL_LOCALVERSION=${LOCALVERSION:--sdm660-gcc+}
WORK="$BUILD/arch-initramfs-root"
MODULES_ROOT="$BUILD/modules-gcc-root"
MODULES_ARCHIVE=${MODULES_ARCHIVE:-$BUILD/modules-r11t-gcc.tar.zst}
RAMDISK="$BUILD/r11t-arch-initramfs.cpio.gz"
KERNEL_DTB="$BUILD/arch/arm64/boot/Image.gz-dtb"
OUTPUT=${OUTPUT:-$BUILD/boot-r11t-arch-gcc.img}

[ -x "$BUSYBOX" ] || {
	echo "ERROR: static AArch64 busybox not found at $BUSYBOX" >&2
	echo "Run scripts/build-diag-image.sh first or set BUSYBOX=." >&2
	exit 1
}
command -v gcc >/dev/null
command -v ld.bfd >/dev/null
command -v depmod >/dev/null
command -v zstd >/dev/null

make -C "$LINUX" O="$BUILD" ARCH=arm64 LOCALVERSION= \
	CC=gcc LD=ld.bfd sdm660_defconfig
"$LINUX/scripts/config" --file "$BUILD/.config" \
	--set-str LOCALVERSION "$KERNEL_LOCALVERSION" \
	--disable LOCALVERSION_AUTO
make -C "$LINUX" O="$BUILD" ARCH=arm64 LOCALVERSION= \
	CC=gcc LD=ld.bfd olddefconfig
make -C "$LINUX" O="$BUILD" ARCH=arm64 LOCALVERSION= \
	CC=gcc LD=ld.bfd -j"$(nproc)" \
	Image.gz qcom/sdm660-oppo-r11t.dtb modules

kernel_release=$(make -s -C "$LINUX" O="$BUILD" ARCH=arm64 \
	LOCALVERSION= CC=gcc LD=ld.bfd kernelrelease)
kernel_version=$(make -s -C "$LINUX" O="$BUILD" ARCH=arm64 kernelversion)
expected_release="$kernel_version$KERNEL_LOCALVERSION"
if [ "$kernel_release" != "$expected_release" ]; then
	echo "ERROR: expected kernel release $expected_release, got $kernel_release" >&2
	exit 1
fi
grep -q 'LINUX_COMPILER.*gcc' "$BUILD/include/generated/compile.h" || {
	echo 'ERROR: kernel was not built with GCC' >&2
	exit 1
}

rm -rf "$MODULES_ROOT"
make -C "$LINUX" O="$BUILD" ARCH=arm64 LOCALVERSION= \
	CC=gcc LD=ld.bfd modules_install \
	INSTALL_MOD_PATH="$MODULES_ROOT" INSTALL_MOD_STRIP=1
rm -f "$MODULES_ROOT/lib/modules/$kernel_release/build" \
	"$MODULES_ROOT/lib/modules/$kernel_release/source"
depmod -b "$MODULES_ROOT" "$kernel_release"
tar --zstd -cf "$MODULES_ARCHIVE" -C "$MODULES_ROOT" \
	"lib/modules/$kernel_release"

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
(( image_size <= 64 * 1024 * 1024 && image_size % 4096 == 0 )) || {
	echo 'ERROR: production image is not page-aligned or exceeds boot' >&2
	exit 1
}

printf 'GCC kernel release: %s\n' "$kernel_release"
printf 'Production ramdisk end: 0x%x (%d bytes free)\n' \
	$((0x83000000 + ramdisk_size)) $((ramdisk_limit - ramdisk_size))
sha256sum "$OUTPUT" "$MODULES_ARCHIVE"
unpack_bootimg --boot_img "$OUTPUT" --format=info
