# Arch Linux ARM for OPPO R11T

This directory contains the reproducible userspace and boot integration for an
Arch Linux ARM installation on the OPPO R11T. Generated files, firmware,
partition dumps, passwords, SSH keys, and flashable images are intentionally
excluded from Git.

The installation keeps the factory GPT. `userdata` is the Btrfs system disk,
`system` is a Btrfs offline rescue disk, and the Android boot image partitions
continue to carry the kernel, DTB, and initramfs.

## Safety model

- `boot`, `bootbak`, and `recovery` are raw Android boot image partitions.
- `vendor`, `modem`, `persist`, and all Qualcomm boot/calibration/NV partitions
  remain untouched.
- Formatting scripts require an explicit destructive confirmation and exact
  partition-size match.
- The installer recovery exposes an ACM control console and a USB ECM link at
  `172.31.66.1/24`. Configfs mass storage is not used because it is unstable on
  this device.
- Storage writes require an installer built with `--write`, an explicit target,
  byte count, SHA-256, and confirmation. The receiver verifies the same byte
  range by reading it back from eMMC.
- Kernel updates produce an image but never flash it from a pacman hook.

## Build order

1. Build the root and rescue Btrfs images on exact-size loop devices with
   `scripts/install-arch-rootfs.sh` and `scripts/prepare-rescue-filesystem.sh`.
2. Build and verify the production boot image with
   `scripts/build-arch-boot-image.sh`.
   `scripts/build-arch-boot-image-gcc.sh` builds a separate native-GCC image
   and complete module archive under `linux/build-gcc`. Its
   `-sdm660-gcc+` kernel release keeps GCC modules separate from the Clang
   rollback image.
3. Build `scripts/build-installer-image.sh --target all --write`, flash only the
   recovery partition, and boot it.
4. Run `scripts/configure-installer-network.sh` on the host.
5. Start `receive_arch_image --target system|userdata` on ACM, then stream each
   image with `scripts/send-arch-image.sh --target system|userdata`.
6. Send the production boot image with `receive_arch_boot`; it verifies the
   complete old boot copy in `bootbak` before replacing `boot`.

The first installed account is `alarm`. The installer prompts for both root and
user passwords unless `R11T_SKIP_PASSWORDS=1` is explicitly set.
