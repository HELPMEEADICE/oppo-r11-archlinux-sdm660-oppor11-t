#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/hedc/OPPO_R11_Mainline
LINUX="$ROOT/linux"
BUILD="$LINUX/build"
SRC_INIT="$ROOT/initramfs"
IR="$BUILD/initramfs-root"
KVER=$(make -C "$LINUX" O=build ARCH=arm64 LLVM=1 -s kernelrelease)

echo "Kernel release: $KVER"

# Preserve busybox if present; rebuild root otherwise.
mkdir -p "$IR"/{bin,lib/modules,lib/firmware,dev,proc,sys,mnt/vendor,mnt/modem}

if [ ! -x "$IR/bin/busybox" ] && [ -x "$IR/bin/busybox.static" ]; then
	cp -a "$IR/bin/busybox.static" "$IR/bin/busybox"
fi
if [ ! -x "$IR/bin/busybox" ]; then
	echo "ERROR: missing $IR/bin/busybox" >&2
	exit 1
fi

cp -a "$SRC_INIT/init" "$IR/init"
chmod 0755 "$IR/init"
cp -a "$SRC_INIT/gpu-msm-probe" "$IR/bin/gpu-msm-probe"
chmod 0755 "$IR/bin/gpu-msm-probe"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra \
	-o "$IR/bin/nl80211-scan" "$SRC_INIT/nl80211-scan.c"
llvm-strip "$IR/bin/nl80211-scan"
if [ -x /tmp/opencode/tqftpserv/tqftpserv.static ]; then
	cp -a /tmp/opencode/tqftpserv/tqftpserv.static "$IR/bin/tqftpserv"
fi
if [ -x /tmp/opencode/diag/diag-router ]; then
	cp -a /tmp/opencode/diag/diag-router "$IR/bin/diag-router"
fi
for tool in rmtfs tqftpserv diag-router; do
	if [ ! -x "$IR/bin/$tool" ]; then
		echo "ERROR: missing static diagnostic tool $IR/bin/$tool" >&2
		exit 1
	fi
	chmod 0755 "$IR/bin/$tool"
done

# Display / touch modules already used previously.
mods=(
	"$BUILD/drivers/soc/qcom/mdt_loader.ko"
	"$BUILD/drivers/soc/qcom/ocmem.ko"
	"$BUILD/drivers/soc/qcom/ubwc_config.ko"
	"$BUILD/drivers/soc/qcom/llcc-qcom.ko"
	"$BUILD/drivers/soc/qcom/qcom_aoss.ko"
	"$BUILD/drivers/regulator/qcom-oledb-regulator.ko"
	"$BUILD/drivers/gpu/drm/drm_exec.ko"
	"$BUILD/drivers/gpu/drm/scheduler/gpu-sched.ko"
	"$BUILD/drivers/gpu/drm/drm_gpuvm.ko"
	"$BUILD/drivers/media/cec/core/cec.ko"
	"$BUILD/drivers/gpu/drm/display/drm_display_helper.ko"
	"$BUILD/drivers/gpu/drm/display/drm_dp_aux_bus.ko"
	"$BUILD/drivers/gpu/drm/panel/panel-samsung-s6e3fa3.ko"
	"$BUILD/drivers/gpu/drm/msm/msm.ko"
	"$BUILD/drivers/input/rmi4/rmi_core.ko"
	"$BUILD/drivers/input/rmi4/rmi_i2c.ko"
	# Wi-Fi stack
	"$BUILD/lib/crypto/libarc4.ko"
	"$BUILD/net/rfkill/rfkill.ko"
	"$BUILD/net/wireless/cfg80211.ko"
	"$BUILD/net/mac80211/mac80211.ko"
	"$BUILD/drivers/net/wireless/ath/ath.ko"
	"$BUILD/drivers/soc/qcom/qmi_helpers.ko"
	"$BUILD/drivers/soc/qcom/rmtfs_mem.ko"
	"$BUILD/drivers/soc/qcom/qcom-r11t-memshare.ko"
	"$BUILD/drivers/soc/qcom/qcom_pdr_msg.ko"
	"$BUILD/drivers/soc/qcom/pdr_interface.ko"
	"$BUILD/drivers/soc/qcom/qcom_pd_mapper.ko"
	"$BUILD/drivers/net/ipa2-lite/ipa2-lite.ko"
	"$BUILD/net/qrtr/qrtr.ko"
	"$BUILD/net/qrtr/qrtr-smd.ko"
	"$BUILD/drivers/remoteproc/qcom_pil_info.ko"
	"$BUILD/drivers/remoteproc/qcom_common.ko"
	"$BUILD/drivers/remoteproc/qcom_sysmon.ko"
	"$BUILD/drivers/remoteproc/qcom_q6v5.ko"
	"$BUILD/drivers/remoteproc/qcom_q6v5_mss.ko"
	"$BUILD/drivers/net/wireless/ath/ath10k/ath10k_core.ko"
	"$BUILD/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko"
)

rm -f "$IR"/lib/modules/*.ko
for m in "${mods[@]}"; do
	if [ ! -f "$m" ]; then
		echo "WARN: missing module $m" >&2
		continue
	fi
	cp -a "$m" "$IR/lib/modules/"
done

# GPU firmware (OPPO signed ZAP + A530 microcode used by A512).
mkdir -p "$IR/lib/firmware/qcom"
cp -a "$ROOT"/device-info/firmware/gpu/a530_pm4.fw "$IR/lib/firmware/qcom/"
cp -a "$ROOT"/device-info/firmware/gpu/a530_pfp.fw "$IR/lib/firmware/qcom/"
cp -a "$ROOT"/device-info/firmware/gpu/a530_pm4.fw "$IR/lib/firmware/"
cp -a "$ROOT"/device-info/firmware/gpu/a530_pfp.fw "$IR/lib/firmware/"
cp -a "$ROOT"/device-info/firmware/gpu/a512_zap.* "$IR/lib/firmware/"
ln -sfn a512_zap.mdt "$IR/lib/firmware/a512_zap.mbn"

# Touch firmware (read-only archive in image; not auto-flashed).
mkdir -p "$IR/lib/firmware/tp/16051"
cp -a "$ROOT"/device-info/firmware/tp/* "$IR/lib/firmware/tp/16051/"

# ath10k host firmware.
mkdir -p "$IR/lib/firmware/ath10k/WCN3990/hw1.0"
cp -a /usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin \
	"$IR/lib/firmware/ath10k/WCN3990/hw1.0/"
cp -a /usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin \
	"$IR/lib/firmware/ath10k/WCN3990/hw1.0/"
# R11T BDF reference (for later board-2 packaging; not consumed raw by ath10k).
cp -a "$ROOT"/device-info/firmware/wifi/bdwlan_16051.bin \
	"$IR/lib/firmware/ath10k/WCN3990/hw1.0/" || true

# Regulatory DB if present on host or staged under /tmp/opencode.
for f in /tmp/opencode/regulatory.db /tmp/opencode/regulatory.db.p7s \
	/usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s \
	/lib/firmware/regulatory.db /lib/firmware/regulatory.db.p7s; do
	[ -f "$f" ] && cp -a "$f" "$IR/lib/firmware/" || true
done

# Rebuild DTB (touch DTS changes) and image.
make -C "$LINUX" O=build ARCH=arm64 LLVM=1 -j"$(nproc)" \
	qcom/sdm660-oppo-r11t.dtb Image.gz

# Pack initramfs.
(
	cd "$IR"
	find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > "$BUILD/r11t-initramfs.cpio.gz"

# Append DTB to Image.gz for Qualcomm bootloader selection.
cp "$BUILD/arch/arm64/boot/Image.gz" "$BUILD/arch/arm64/boot/Image.gz-dtb"
dd if="$BUILD/arch/arm64/boot/dts/qcom/sdm660-oppo-r11t.dtb" \
	of="$BUILD/arch/arm64/boot/Image.gz-dtb" oflag=append conv=notrunc status=none

# Kernel at 0x80008000 expands ~27MiB. Firmware reserved begins at 0x85600000.
# Keep ramdisk below that: use 0x83000000 (base 0x80000000 + 0x03000000),
# leaving ~38MiB before 0x85600000. Do NOT use 0x84000000 once initramfs >22MiB.
mkbootimg \
	--kernel "$BUILD/arch/arm64/boot/Image.gz-dtb" \
	--ramdisk "$BUILD/r11t-initramfs.cpio.gz" \
	--pagesize 4096 \
	--base 0x80000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x03000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x00000100 \
	--header_version 1 \
	--os_version 9.0.0 \
	--os_patch_level 2019-09 \
	--cmdline 'console=tty0 console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 earlycon=msm_serial_dm,0xc170000 androidboot.hardware=qcom user_debug=31 printk.devkmsg=on loglevel=8 ignore_loglevel keep_bootcon panic=10 root=/dev/ram0 rw rdinit=/init init=/init' \
	-o "$BUILD/recovery-r11t-diag.img"

echo "=== image info ==="
unpack_bootimg --boot_img "$BUILD/recovery-r11t-diag.img" --format=info
sha256sum "$BUILD/recovery-r11t-diag.img"
ls -lh "$BUILD/recovery-r11t-diag.img" "$BUILD/r11t-initramfs.cpio.gz"
echo "modules:"; ls -1 "$IR/lib/modules" | wc -l
du -sh "$IR" "$IR/lib/firmware" "$IR/lib/modules"
