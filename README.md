# Arch Linux ARM for OPPO R11T

Arch Linux ARM deployment, recovery, and hardware-integration sources for the
OPPO R11T (`oppo,r11t`) mainline Linux port. The deployed system uses Btrfs on
the original Android `userdata` partition, systemd, KDE Plasma/Wayland,
PipeWire, NetworkManager, and the device-specific mainline kernel.

Start with [`archlinux/README.md`](archlinux/README.md). The repository includes
the rootfs package manifest and overlay, production and installer initramfs
sources, ECM streaming installer, verified boot-image update and rollback
tools, and the shared diagnostics required by the image builders.

Related source repositories:

- Kernel: <https://github.com/HELPMEEADICE/linux-sdm660-oppor11-t>
- RMTFS: <https://github.com/HELPMEEADICE/rmtfs-sdm660-oppor11-t>
- General tools: <https://github.com/HELPMEEADICE/oppo-r11-mainline-tools-sdm660-oppor11-t>

The build scripts expect the kernel checkout at `./linux`. This public source
repository intentionally excludes device firmware, partition backups,
generated images, passwords, SSH keys, MAC addresses, and extracted device
data. Firmware and account credentials are supplied locally at build or runtime
from the device's preserved read-only partitions.

See `OPPO_R11T_WIFI_MAINLINE_BRINGUP.md` for the WCN3990 bring-up history,
protocol details, known issues, and hardware validation evidence.
