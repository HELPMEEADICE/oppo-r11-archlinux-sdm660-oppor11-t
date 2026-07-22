# OPPO R11T 主线 Linux Wi-Fi 适配复盘

## 1. 最终结果

OPPO R11T 的 WCN3990 Wi-Fi 已在当前主线 Linux 诊断系统中完成硬件验证。

最终冷启动测试满足以下条件：

- MSS/MPSS 保持 `running`，不再在启动后约 0.28 秒触发无消息 fatal。
- AP 侧 RFSA 能响应 client 1 和 client 4 的共享内存地址查询。
- RMTFS 进入与 stock 一致的 new-client 流程，完成 modem EFS 读取。
- WLAN protection domain 从 `UNINIT` 进入 `0x1fffffff`。
- WLFW QMI 正常出现，ath10k 完成 WCN3990 固件、WMI 和 HTT 初始化。
- `wlan0` 注册并能正常置为 UP。
- nl80211 主动扫描成功，实测发现 2.4 GHz 和 5 GHz AP。
- 最终日志中没有 MSS fatal、ath10k firmware crash、QMI `Too Small Buffer`。

最终硬件验证镜像：

```text
recovery-r11t-diag.img
SHA-256: 4d9fd47f69cb44e93d16d244e3d557e77e3e4d33aa0042e8551557db11b4ff13
size: 45,760,512 bytes (11,172 x 4096-byte pages)
```

镜像的 ramdisk 从 `0x83000000` 加载，结束地址为 `0x850e1b17`，距
`0x85600000` 固件保留区仍有约 5.1 MiB。

当前仍有一个 Wi-Fi 收尾问题：ath10k 没有取得设备的稳定 MAC 地址，每次启动会生成随机 MAC。不能把测试时生成的地址写死到 DTS；后续应从 stock 的持久化校准或 MAC 存储位置接入 nvmem/firmware 数据。

## 2. 为什么这不是普通的 ath10k 适配

R11T 的 WCN3990 不是一块可以由 Linux 单独启动的 PCIe/USB Wi-Fi 芯片。它位于 Qualcomm modem 子系统的 WLAN user protection domain 中，实际启动链为：

```text
MSS/MPSS
  -> GLINK/QRTR
  -> AP 侧 Qualcomm 服务发现
  -> RFSA + RMTFS/EFS
  -> service-registry/PDR
  -> msm/modem/wlan_pd
  -> TQFTP 加载 wlanmdsp.mbn
  -> WLFW QMI
  -> ath10k_snoc
  -> wlan0
```

只要前面任一层不符合 OPPO modem firmware 的旧 ABI，WLFW 就不会发布，ath10k 也无法完成 probe。因此，“`ath10k_snoc.ko` 能加载”或“DTS 中存在 Wi-Fi 节点”都不能证明 Wi-Fi 可用。

## 3. 初始故障表现

早期主线环境可以完成 MBA 验证并打印：

```text
remote processor 4080000.remoteproc is now up
```

但约 0.28 秒后 MPSS 主动退出：

```text
qcom-q6v5-mss 4080000.remoteproc: fatal error without message
```

同时存在以下特征：

- SMEM crash reason item 421 长度为 0，没有断言字符串。
- WLFW QMI 没有出现。
- `wlan0` 不存在。
- 最初连 RMTFS OPEN 都没有发生。
- ath10k 是否预加载不会改变 fatal 的固定时间。

这意味着故障发生在 modem firmware 内部，不能靠普通 kernel panic、call trace 或 ath10k 日志直接定位。

## 4. 先建立可靠的诊断环境

### 4.1 recovery 不是普通的临时启动槽

R11T bootloader 不支持 `fastboot boot`，会返回 `unknown command`。测试只能把诊断镜像写入 recovery，再从 Android 执行：

```sh
adb reboot recovery
```

`fastboot reboot recovery` 不可靠，且 Android 到 recovery 也存在一次性选择竞态：有时第一次会回到 Android，第二次执行 `adb reboot recovery` 才进入主线。这个现象不能误判为新镜像损坏。

### 4.2 initramfs 地址碰撞

早期加入 glibc 工具、firmware 和模块后，ramdisk 增长到约 34 MiB。旧加载地址 `0x84000000` 会越过 `0x85600000` 固件保留边界，症状是无日志、无 USB、静默回 Android。

解决方法：

- ramdisk 改到 `0x83000000`。
- 静态工具 strip。
- 只打包实际需要的模块和 firmware。
- 每次构建计算 `ramdisk_load + compressed_size`，不能只看 boot image 总大小。

### 4.3 诊断脚本必须保留交互 shell

ath10k、PDR 和 remoteproc probe 都可能同步等待。若在 init 前台运行，USB ACM shell 会被占住，表面上像 kernel 卡死。

最终做法是：

```sh
/bin/test_wifi >/tmp/test-console.log 2>&1 &
```

然后通过 ACM 分阶段读取 remoteproc 状态、dmesg、RMTFS 和 TQFTP 日志。

还踩过两个脚本问题：

- 外层重定向发生在命令执行前，所以 `/tmp` 必须在启动后台任务前创建。
- 自动生成 `/bin/test_wifi` 时曾遗漏 shell 循环的 `done`；打包前必须对源 init 和提取后的脚本都执行 `sh -n`。

## 5. 建立 stock 启动时间线

真正推进定位的是 stock Android 冷启动日志，而不是继续猜 DTS。

stock 大致顺序为：

1. MPSS 启动。
2. AP 侧 service-notifier/sysmon 建立连接。
3. RMTFS 打开并读取 `modem_fs1`、`modem_fs2`、`fsg`、`fsc`。
4. RFSA/sharedmem 提供 client buffer 地址。
5. IPA 初始化。
6. `wlan_pd` 由 `UNINIT` 进入 UP。
7. 通过 TQFTP 读取 `wlanmdsp.mbn`。
8. WLFW 出现，ICNSS/ath10k 继续启动。

几个关键时间点：

- stock 的首次 RMTFS OPEN 约在 MSS up 后 116 ms。
- EFS 完成后约 248 ms 才进入下一阶段。
- IPA INIT 约在 MSS up 后 376 ms。

这纠正了多个错误方向：主线最初在进入 EFS 之前就死了，不能把后续的 IPA、WLAN rail 或 ath10k 当作第一根因。

## 6. 排查过但不是最终根因的方向

以下实验并非全部“无用”，其中一些功能最终仍需保留；但它们单独都不能解决固定时间 fatal。

### 6.1 预加载 ath10k 和 WCN 电源

曾怀疑 ath10k 必须在 MSS 前完成 WLAN MSA 或 WCN rail 上电。硬件测试表明：

- 不加载 ath10k，MSS 仍会在同一时间 fatal。
- fatal 后再加载 ath10k触发 MSS recovery，第二次仍在同一阶段退出。
- stock ICNSS 也是在 WLFW 出现后才真正上电和配置 WCN。

结论：ath10k 不是最初的触发点。最终仍让它在第一次 MSS boot 前建立自己的 PDR/MSA 状态，但这不是 RFSA 根因的替代品。

### 6.2 仅加入 ipa2-lite

SDM660 社区树使用 `ipa2-lite`，不是上游 GSI IPA。将其移植到 R11T 后：

- IPA probe 成功。
- 创建 `ipa_lan0` 和 `rmnet_ipa0`。
- AP 侧 IPA QMI `49:101` 正常发布。

但 MPSS 仍在发布 modem IPA `49:102` 前 fatal。因此 ipa2-lite 是完整平台支持的一部分，却不是当时最早的 blocker。

### 6.3 IPA SMMU、uC 和 SRAM 布局

依次测试或修正过：

- `iommu.passthrough=1` 模拟 stock stage-1 bypass。
- IPA AP/uC stream ID 和 SMMU context。
- `qcom,ipa-loaduC` 相关行为。
- OPPO IPA v2.6L 的 SMEM item 497/SRAM 固定布局。
- IPv4 route table `0x348`、IPv6 route table `0x388`、modem header `0x3c8`。

这些差异中，SRAM 布局确实存在 ABI 错位，值得修正；但修正后 fatal 时间完全不变，说明它不是第一个启动依赖。

### 6.4 MSS reset、电源、时钟和内存

排除项包括：

- 保持 `mem_clk` 投票。
- Q6 memory bank 从 `28..0` 扩到 stock 的 `29..0`。
- stock/mainline ACC、BHS、clamp、reset 序列逐项比较。
- MPSS carveout 溢出或 Linux 分配覆盖 modem protected memory。
- recovery/FTM boot mode；曾把镜像临时写入 boot 做严格 normal-mode 测试，结果相同，随后恢复并校验 stock boot/bootbak。
- MBA/MPSS firmware 组合错误；实际直接使用同一 modem 分区，哈希一致。

### 6.5 缺少运行时服务的错误归因

先后加入或检查过：

- RMTFS 和 `rmtfs_mem`。
- `qcom_pdr_msg`、`pdr_interface`、`qcom_pd_mapper`。
- QRTR name service。
- `tqftpserv`。
- DIAG router。
- DHMS/memshare service `0x34/1/1`。
- sysmon/SSCTL。

RMTFS、PDR、TQFTP、DHMS 都是最终环境的真实组成部分，但单独加入某一个服务时，modem 根本没有发请求，所以不能据此认定该服务就是首个 blocker。

### 6.6 WLAN-PD 初始 UNINIT 不是故障

PDR listener 注册后首先返回 `0x7fffffff` (`UNINIT`)。一度认为这就是 fatal 原因。

stock 冷启动证明它也会先得到 UNINIT，之后才收到：

```text
state = 0x1fffffff
```

因此 listener 注册成功但暂时 UNINIT 是正常状态，真正要找的是在它之前缺失的 EFS/RFSA 合约。

### 6.7 coredump 和字符串扫描的局限

remoteproc coredump 成功生成约 129 MiB 的 32 位 ELF segment dump，但：

- ELF 有 28 个 `PT_LOAD`，没有 `PT_NOTE`，因此没有 crash PC/register。
- runtime heap 中还包含动态加载 user-PD 的静态断言字符串。
- 对 dump 运行 `strings` 无法证明哪条断言实际执行。
- 通过 ACM 传完整 dump 只有约 23 KiB/s，实际不可用。
- `recovery=disabled` 会让 crash worker 根本不生成 devcoredump，这是一次额外的诊断陷阱。

结论：没有 register note 的整段物理内存 dump，只适合验证布局和运行时区域，不适合靠字符串直接找控制流。

## 7. QRTR 兼容问题：旧 MPSS 不消费 HELLO replay

主线 QRTR nameserver 会在 remote HELLO 时重放本地服务，但 OPPO 的旧 MPSS 没有在正确阶段消费这次 replay。

决定性实验是：MSS 启动后重新发布 RMTFS service 14，modem 立刻开始 OPEN：

```text
modem_fs1
modem_fs2
fsg
fsc
fsg_oem_1
fsg_oem_2
```

最终在 `net/qrtr/ns.c` 中保留一次 HELLO 后 110 ms 的本地服务 reannounce：

```c
/* OPPO's older MPSS starts its RMTFS client about 110 ms after HELLO. */
mod_delayed_work(..., msecs_to_jiffies(110));
```

踩过的弯路：

- +6 ms、+50 ms、+110 ms 都做过单变量测试。
- 50/100/150/200/250 ms 周期重放也测试过。
- 单纯改变公告时机不能决定 old/new-client RMTFS 协议分支。
- 重放解决的是“modem 看不到 AP server”，不是后面的 RFSA 协商。

## 8. RMTFS 兼容层

### 8.1 OPPO OEM 路径不能拒绝

modem 会请求：

```text
/boot/modem_fsg_oem_1
/boot/modem_fsg_oem_2
/oppo/oem_partion
```

最终映射：

- `modem_fsg_oem_1` -> `oppostanvbk`（静态 NV backup）。
- `modem_fsg_oem_2` -> `oppodycnvbk`（动态 NV backup）。
- `/oppo/oem_partion` -> `oppostanvbk`。

所有硬件测试都使用 RMTFS `-r`：读取真实 NV 分区，写操作进入 shadow buffer，避免修改 modem NV。

### 8.2 old-client 与 new-client 的误导

缺少 RFSA 时，MPSS 首次 ALLOC 为 2 MiB，进入 old-client 路径。stock 首次 ALLOC 则为 0，代表 new-client dummy/negotiation。

为解释差异，曾逐项测试：

- RMTFS 固定 port 14 与动态 QRTR port。
- OPEN response caller ID：数组索引与 stock 的真实 partition fd。
- QMI IDL v1.2、TLV 类型、response aggregate 和 wire bytes。
- 4094 sector 分别读取与单次批量 `pread(2,096,128)`。
- 服务公告时间。
- client 4 pool routing。

这些改动都没有让 ALLOC 从 2 MiB 变成 0。根因在更早的 RFSA shared-memory discovery，而不是 RMTFS OPEN response。

### 8.3 new-client IOVEC 使用相对 offset

RFSA 修好后，MPSS 首次进入 new-client 路径，但第一笔 512-byte IOVEC 失败。

日志中的地址是：

```text
phys_offset = 0x200
```

现有 RMTFS 只接受绝对物理地址，按 `0x200 - 0x85e00000` 计算导致无符号下溢。最终共享内存访问同时支持：

- 小于 buffer base 的值按相对 offset 解释。
- 位于 buffer 物理范围内的值按绝对地址解释。
- 两种模式统一做 `offset + length <= size` 边界检查。

该修正后以下事务全部成功：

```text
ALLOC size=0 -> 0x85e00000
IOVEC sector 1, count 1, offset 0x200
IOVEC sector 2, count 4094, offset 0x400
OEM OPEN/ALLOC/IOVEC
```

## 9. 真正根因：缺少 RFSA shared-memory discovery

### 9.1 stock 服务身份

stock kernel 的 `sharedmem_qmi` 提供：

```text
service:  0x1c
version:  1
instance: 1
raw QRTR instance: 0x101
message: GET_BUFF_ADDR (0x23)
```

它向 modem 返回两个 client：

| client | 用途 | 地址 | 大小 |
|---|---|---:|---:|
| 1 | RMTFS | `0x85e00000` | 2 MiB |
| 4 | OPPO OEM backup | `0xf6b00000` | 1 MiB |

旧 OPPO MPSS 必须先发现 RFSA 并拿到这些地址，才会选择 stock 的 RMTFS new-client 流程。

### 9.2 最小 RFSA server

RFSA 被加入 R11T 的本地 Qualcomm 服务模块：

```text
drivers/soc/qcom/qcom_r11t_memshare.c
```

这个模块现在同时承担：

- DHMS/memshare service `0x34/1/1`。
- RFSA service `0x1c/1/1`。
- R11T 启动期 WLAN PDR listener。

第一次 RFSA 请求已经证明根因：

```text
client=1 size=2097152 address=0x85e00000
```

MSS 立即越过旧 fatal 点。但第一版 response 编码失败：

```text
qmi_encode: Too Small Buffer
qmi_send_response: -525
```

原因是 C response struct 为 16 bytes，而实际 QMI wire response 需要 18 bytes。`qmi_send_response()` 的 max length 参数是 wire buffer 上限，不是 `sizeof(struct)`。RFSA 改为 18 后，RMTFS 首次 ALLOC 立即从 2 MiB 变为 0，完成因果验证。

同类问题也存在于 DHMS query/free response。最终这些 response 使用模块 QMI handle 的 wire max buffer，不再传 C struct 大小。

## 10. client 4 的 SCM 权限陷阱

RFSA client 1 和 EFS 成功后，modem 请求 client 4：

```text
client=4 size=1048576 address=0xf6b00000
```

随后仍会 fatal。最容易误判之处是：stock running DTS 的 client 4 节点没有 `qcom,vmid`，看起来无需 SCM assignment。

但 stock `sharedmem-uio` driver 会在 probe 中对动态 client 4 内存显式执行等价于：

```text
HLOS -> HLOS + MSS_MSA
```

主线 `rmtfs_mem` 只有 DTS 含 `qcom,vmid` 才调用 `qcom_scm_assign_mem()`。因此最终 DTS 必须写：

```dts
rmtfs_oem_mem: memory@f6b00000 {
	compatible = "qcom,rmtfs-mem";
	reg = <0x0 0xf6b00000 0x0 0x100000>;
	no-map;
	qcom,client-id = <4>;
	qcom,vmid = <QCOM_SCM_VMID_MSS_MSA>;
};
```

补上权限后，MSS 第一次长期保持 `running`，并开始请求 TQFTP 文件。这是从 EFS/RFSA 阶段进入 WLAN user-PD 阶段的分界点。

工程教训：不能只比较 DT 属性，还必须比较 stock driver 在 probe/notifier 中隐式执行的 SCM、clock、power 和 memory ownership 操作。

## 11. TQFTP 路径翻译陷阱

MSS 稳定后，TQFTP 日志出现：

```text
/readonly/firmware/image/wlanmdsp.mbn
/readonly/vendor/firmware/wlanmdsp.mbn
/readonly/firmware/image/modem_pr/...
```

文件实际位于：

```text
/mnt/modem/image/wlanmdsp.mbn
/mnt/modem/image/modem_pr/
```

最初直接创建 `/readonly/...` symlink 仍然返回 ENOENT。原因是 tqftpserv 不直接 `open()`请求中的绝对路径，而会翻译：

```text
/readonly/firmware/image/...  -> /lib/firmware/...
/readonly/vendor/firmware/... -> /lib/firmware/...
/readwrite/...                 -> /var/lib/tqftpserv/...
```

最终 init 在 MSS 启动前建立：

```sh
ln -sfn /mnt/modem/image/wlanmdsp.mbn /lib/firmware/wlanmdsp.mbn
ln -sfn /mnt/modem/image/modem_pr /lib/firmware/modem_pr
```

随后 `wlanmdsp.mbn` 的 3,482,972 bytes 经 454 个 TQFTP block 完整传输，WLAN-PD 立即进入 UP，WLFW 和 ath10k 随后出现。

## 12. PDR 和模块顺序

曾出现 AP-local `qcom_pd_mapper` 抢先匹配 PDR handle 的竞态。若 mapper 与 lookup 顺序不对，ath10k 会阻塞在 `qcom_rproc_pds_attach()`，等待永远不会到来的 remote domain state。

可靠顺序是：

1. 加载 QRTR、`qcom_pdr_msg` 和 `pdr_interface`。
2. R11T 服务模块先创建 `wlan/fw` lookup。
3. AP-local `qcom_pd_mapper` 发布静态映射：

   ```text
   wlan/fw -> msm/modem/wlan_pd, instance 180
   ```

4. 加载 MSS remoteproc 和 ath10k。
5. 第一次 MSS boot 时 listener 已存在，modem notifier service 出现后立即注册。

完全延后 local mapper 也不对：旧 MPSS 在 fatal 前不会先发布可供查询的 remote locator，AP 侧需要 local mapper 提供静态 domain 映射。

## 13. 最终实现清单

### Kernel/DTS

- `arch/arm64/boot/dts/qcom/sdm660-oppo-r11t.dts`
  - 修正 MPSS/MBA/ADSP/CDSP reserved-memory。
  - 增加 client 4 `0xf6b00000/1 MiB`。
  - 为 client 4 分配 `QCOM_SCM_VMID_MSS_MSA`。
  - 启用 R11T memshare/RFSA 服务和 MSS/Wi-Fi 节点。
- `drivers/soc/qcom/qcom_r11t_memshare.c`
  - DHMS `0x34/1/1`。
  - RFSA `0x1c/1/1`, message `0x23`。
  - WLAN PDR lookup/listener。
- `drivers/soc/qcom/qcom_r11t_memshare_qmi.[ch]`
  - Qualcomm memshare QMI IDL encoding tables。
- `drivers/net/ipa2-lite/`
  - SDM660 IPA2/BAM 支持。
- `net/qrtr/ns.c`
  - remote HELLO 后 110 ms 重放 AP-local services。
- `drivers/soc/qcom/pdr_interface.c`
  - 调试和兼容旧 MPSS 的 PDR lookup/registration 路径。

### RMTFS 用户空间

- 保留 service 14/raw instance 1。
- 使用动态 QRTR server port。
- 支持 SIGUSR1 same-socket republish（早期单变量诊断能力）。
- OPPO OEM partition aliases。
- fd 风格 OPEN caller ID。
- 批量连续 I/O。
- new-client 相对 offset 和旧绝对地址双兼容。
- `-r` shadow-write，禁止硬件测试修改真实 NV。

### initramfs

- `initramfs/init`
  - 正确挂载 modem/vendor firmware。
  - 在 MSS 前建立 `wlanmdsp.mbn` 和 `modem_pr` TQFTP 映射。
  - 按顺序启动 RFSA/DHMS/PDR、TQFTP、RMTFS、MSS 和 ath10k。
  - Wi-Fi 测试后台运行，保留 ACM shell。
- `initramfs/nl80211-scan.c`
  - 无 libnl 依赖的静态 nl80211 scanner。
  - 自动置接口 UP、触发 wildcard scan、输出 BSSID/频率/信号/SSID。
- `scripts/build-diag-image.sh`
  - 编译并 strip scanner。
  - 校验持久化静态工具和模块。
  - ramdisk 固定放在 `0x83000000` 并检查边界。

## 14. 最终硬件证据

一次完全冷启动、无需 live 修改或 MSS 二次重启的结果：

```text
remoteproc0 state: running
RFSA client 1: 0x85e00000 / 2 MiB
RFSA client 4: 0xf6b00000 / 1 MiB
WLAN PD state: 0x1fffffff
ath10k target: wcn3990 hw1.0
HTT version: 3.50
netdev: wlan0
```

自动 nl80211 scan 共发现 8 个 AP：

- 2.4 GHz: 2412/2452/2462 MHz。
- 5 GHz: 5180 MHz。
- 最强实测信号约 -31 dBm。

扫描退出码为 0，MSS 在扫描后仍为 `running`，没有 firmware crash。

最终镜像内关键文件哈希：

```text
nl80211-scan:
5f8bfd07ea55e418f93c4bce314ceec52361d1875dd84885b96c27c674a37509

rmtfs:
65d7b5c50b595b8c961deaabb3622ef9f9e0c2af749c681541eb7445350ea3f4

qcom-r11t-memshare.ko:
9e61355d5dcdd841c93bb6e11aacfb2f13823a21ef054b3d84e9196917ba2c40
```

## 15. 测试和校验命令

构建：

```sh
cd /home/hedc/OPPO_R11_Mainline
sh -n initramfs/init
./scripts/build-diag-image.sh
```

进入主线 recovery 后：

```sh
mkdir -p /tmp
/bin/test_wifi >/tmp/test-console.log 2>&1 &
```

检查结果：

```sh
cat /sys/class/remoteproc/remoteproc0/state
ls /sys/class/net
sed -n '/=== nl80211 scan ===/,/=== dmesg wifi ===/p' /tmp/test-console.log
dmesg | grep -Ei 'fatal error|firmware crash|Too Small Buffer|failed to send.*response'
```

写 recovery 后必须按当前镜像的精确页数回读，不能沿用旧镜像长度：

```sh
dd if=/dev/block/bootdevice/by-name/recovery bs=4096 count=11172 2>/dev/null | sha256sum
```

本次曾因沿用旧的 `count=11100` 得到错误哈希。写入本身是完整的，错误只在回读长度少了 72 页。任何哈希不一致都应先检查镜像实际字节数是否能整除 page size，以及回读 count 是否对应当前镜像。

## 16. 后续工作

1. 找到 stock 的稳定 WLAN MAC 来源，通过 nvmem、persist 数据或正确 firmware/calibration 接口提供给 ath10k。
2. 将 RMTFS 本地修改整理成项目内可重复构建的源码或正式 patch，避免只依赖 initramfs staging 中的静态二进制。
3. 收敛 `pdr_interface`、Q6V5 和 QRTR 中仅用于定位的详细日志，保留必要兼容逻辑。
4. 评估 HELLO 后 110 ms reannounce 是否应做成旧 firmware quirk，而不是无条件影响所有 QRTR remote node。
5. 增加关联和 DHCP 测试；当前已经验证扫描收发，但尚未在诊断 initramfs 中加入 wpa_supplicant 完成受控入网。
6. 独立验证 suspend/resume、flight mode、重复 MSS SSR 后 Wi-Fi 的恢复能力。

## 17. 核心经验

- 先画出完整跨子系统启动链，再决定在哪一层加日志。
- “模块加载成功”“remoteproc up”“wlan0 存在”都只是中间里程碑，最终必须做真实射频操作。
- 固定时间 firmware fatal 往往是缺少启动合约，不一定是内核访问异常。
- stock DT 只描述数据；stock driver 中隐式的 SCM assignment 和 notifier 行为同样属于硬件 ABI。
- QMI encoder 的 max length 是 wire 上限，不能机械使用 `sizeof(C struct)`。
- 协议字段名不一定代表绝对物理地址；必须用实际请求值验证相对/绝对语义。
- 对旧 Qualcomm firmware，服务号正确不等于服务发现时序正确。
- 每次硬件实验只改变一个变量，并明确“什么结果能证伪当前假设”。
- 诊断镜像必须可恢复、可校验、保留交互 shell，并始终避免写真实 NV。
