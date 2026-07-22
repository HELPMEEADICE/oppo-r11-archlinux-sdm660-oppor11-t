# OPPO R11T Mainline Tools

Diagnostic initramfs sources, image-building scripts, and bring-up notes for
the OPPO R11T (`oppo,r11t`) mainline Linux port.

Related source repositories:

- Kernel: <https://github.com/HELPMEEADICE/linux-sdm660-oppor11-t>
- RMTFS: <https://github.com/HELPMEEADICE/rmtfs-sdm660-oppor11-t>

The build scripts expect the kernel checkout at `./linux` and intentionally do
not include device firmware, partition backups, generated images, or extracted
device data.

See `OPPO_R11T_WIFI_MAINLINE_BRINGUP.md` for the WCN3990 bring-up history,
protocol details, known issues, and hardware validation evidence.
