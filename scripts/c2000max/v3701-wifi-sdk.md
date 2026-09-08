# C2000MAX 37.01 Wi-Fi SDK 与公开小补丁评估

核查日期：2026-09-08。先完整读取用户提供的 `C2000MAX_25.12_6.12_WiFi_HNAT_Codex_2026-09-08.md`，随后只读检查 WSL 源码、缓存、prepared 驱动及既有 rootfs，并下载作者公开的文档、包定义、Release 元数据和两个小补丁。本子任务未修改源码仓库、未运行 make、未生成镜像、未接触设备。

## 结论

37.01 主线保留现有整套 Wi-Fi SDK：实际主驱动 **8.3.1.2**，主驱动/HWIFI 快照 `20250613-415824`，WARP `20250613-433271`，OSAL `543726`。可以继续完成独立的 HNAT 修复。

新版 8.3.1.3 的存在有一手资料支持，但本次没有取得三个新版 tarball，也没有找到可实际下载的作者或官方公开 URL。用户随后确认手头也没有新版 SDK。不能只修改包名或混搭新旧 WARP/HWIFI。

两个公开小补丁中：MAC 补丁缺本地配套 API，不作为独立更新合入；FW_HDR 是可独立评估的固件装载/模块体积优化，但改变启动固件来源，当前无实机验证，保留为后续候选，不并入本次 HNAT 主线。

## 本地实际版本与完整性

检查目录：`/home/wkz/c2000max-v36.01-build`。检查初始 HEAD：`763b31f97c72d20376d1ab4b7650651f4a706e2d`，即父任务给定 V36.5 基线。

已展开源码 `build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/mt_wifi7/mt_wifi/include/os/rt_linux.h:140` 定义 `AP_DRIVER_VERSION "8.3.1.2"`。这是源码版本证据，不是设备运行版本证明。

| 本地缓存文件 | 本次实际计算 SHA-256 | 结论 |
|---|---|---|
| `mt7993_20250613-415824.tar.xz` | `e2900a672a5151aed85f6711240db1ddcf5eed317fd620485a0ee6aee060cfb4` | 与本地 Makefile、作者 Release digest 一致 |
| `warp_20250613-433271.tar.xz` | `6537088695c124135b695bf4ce6d4f9febecd3fb41889c4419de77780dca6488` | 与本地 Makefile、作者 Release digest 一致 |
| `mt_wifi_osal-543726.tar.xz` | `102bf755e7d5b8a92767068ff03abe44ede05a2158936e76a793244acdb6d25a` | 与本地 Makefile、作者 Release digest 一致 |

现有可验证公开来源：[chasey-dev/objs v1](https://github.com/chasey-dev/objs/releases/tag/v1)。包定义中主驱动、HWIFI、CMN 使用同一份主源码包；OSAL 已启用。`.config` 的 MAX 选择为 `MTK_HWIFI_MT7993=y`、`MTK_WIFI7_CHIP_MT7993=y`、SKU `BE3600`；不能按芯片商业名称自行改成 HiGoWRT 的 MT7992/BE3600SDB 组合。

加速配套保留：`MTK_HWIFI_WED_SUPPORT=y`、`MTK_WIFI7_FAST_NAT_SUPPORT=y`、`MTK_WIFI7_WHNAT_SUPPORT=m`、`WARP_CHIPSET="mt7987"`、`WARP_VERSION="3_1"`、`WARP_BM_SHRINK_RING=y`、`WARP_RX_PAGE_BM_NUM=8192`。WARP 已有 `008-warp_bm_shrink_ring.patch`，不是待新增功能。既有 prepared 内核 `linux-6.12.94/Module.symvers` 可见 `mtk_check_wifi_busy`、`mtk_set_pse_drop`、`ra_sw_nat_hook_tx`、`ppe_dev_register_hook` 等厂商链路符号；这支持配套关系，不能替代 HNAT/Wi-Fi 实机验证。

## 新版 SDK 获取核查

- 通过 GitHub API 重新获取 HiGoWRT 当前 main，仍为 `25a3aefa7be5821fa7e5e4809ac34a09fa62ef24`，与参考 MD 固定快照相同。
- [HiGoWRT README](https://github.com/Hiveton/higowrt/blob/25a3aefa7be5821fa7e5e4809ac34a09fa62ef24/README.md) 明确三个包来自 SDK 的 `dl/`，因体积与授权原因不随 git 提供。其 [Releases API](https://api.github.com/repos/Hiveton/higowrt/releases) 本次返回 `[]`。
- 实际下载并检查 [mt_wifi7 Makefile](https://github.com/Hiveton/higowrt/blob/25a3aefa7be5821fa7e5e4809ac34a09fa62ef24/package/mtk/drivers/mt_wifi7/Makefile)、[mt_hwifi Makefile](https://github.com/Hiveton/higowrt/blob/25a3aefa7be5821fa7e5e4809ac34a09fa62ef24/package/mtk/drivers/mt_hwifi/Makefile)、[WARP Makefile](https://github.com/Hiveton/higowrt/blob/25a3aefa7be5821fa7e5e4809ac34a09fa62ef24/package/mtk/drivers/warp/Makefile)：它们给出新版包名，`PKG_SOURCE_URL` 均为空，未给出 `PKG_HASH`。OSAL 定义只有包名，没有下载 URL 和 hash。
- [chasey-dev/objs Releases API](https://api.github.com/repos/chasey-dev/objs/releases) 本次只有 v1，其四个资产是旧主驱动、旧 WARP、旧 OSAL 和 datconf。没有新版三个包。chasey `25.12-dev-wifi7` 当前 HEAD 仍为 `1b6fa75ca02aa7a7dd6d0b6c68865f16eef5ae0f`。
- [IOPSYS MR 1486](https://dev.iopsys.eu/feed/targets/-/merge_requests/1486) 记录完整外层 SDK `mtk-wifi-mt7987-mt7990-mt7992-mt7993-v8.3.1.3_SDK-20250919-external.tar.xz`，SHA-256 为 `e1814c2a6726fcf694e452ffc6959a26cf8d5ab0218a246b821ecda3ebbd0119`。记录没有给出该包的直接下载地址。该 SHA 不能用于校验三个内部包；MR 的目标内容包含 5.4 路径，不证明 MAX/6.12 适配。
- 对三个准确文件名及上述官方/作者渠道的检索未得到额外下载来源。结论只限定为“本次未找到可实际取得的授权公开来源”，不声称所有渠道都不存在。

缺口为：`mt7993_20250919-39602c.tar.xz`、`warp_20250919-9c1cfa.tar.xz`、`mt_wifi_osal-a53418.tar.xz` 全部缺失；内部包各自可信 SHA-256 也缺失。后续只有从厂商/SDK 授权渠道拿到完整套件和许可、校验依据后，才可继续。没有探测受限账号或绕过访问控制。

[HiGoWRT 移植记录](https://github.com/Hiveton/higowrt/blob/25a3aefa7be5821fa7e5e4809ac34a09fa62ef24/MIGRATION_ISSUES.md) 涉及 AP-VLAN stub、OSAL RPS 降级、SKU 固件调整和共享 build_dir 的补丁应用问题。其整机配置、示例 EEPROM 及校准不能覆盖 MAX。MAX DTS 明确 NRadio SPI-NOR factory 格式不能直接当 MT7993 EEPROM，依赖单机专属 SD factory e2p；此定制必须保留。

## 公开小补丁评估

### 分频段 MAC 读取：暂不采用

来源：[chasey a85c961d9ca6161873d04a5b3cd9b0f256cb8570](https://github.com/chasey-dev/immortalwrt-mt798x-rebase/commit/a85c961d9ca6161873d04a5b3cd9b0f256cb8570)。原始补丁已保存为 `chasey-mac.patch`，SHA-256 `e9e9508d2d87c58e91494648e76a9c49df09345792c1b1c4fd344bca90ded069`。

对既有 prepared Wi-Fi 源码执行 `patch --dry-run -p1`，两个文件均通过，不代表能编译或可安全运行。补丁新增调用 `mt_mac_address_read_wifi()`，但当前 kernel overlay、patches、prepared `wifi_utility/*.c` 和内核 `Module.symvers` 均无该 API。现有导出是 `mt_eeprom_read_wifi()` 与 `mt_eeprom_write_wifi()`。单独加补丁会产生未解决符号。

完整采用需适配上游 device-scoped MAC/NVMEM 后端，并审查 MAX SD factory 和错误传播。补丁保留 DAT/模块参数优先级，但会把配置的 OF/NVMEM 读取错误转为初始化失败；不能只用 EEPROM 地址看似有效作为合并依据。现有 `013`/`014` 编号已被 MAX 其他补丁使用，后续要使用空闲编号，不能覆盖同序号现有补丁。

### HWIFI FW_HDR 可选：后续可独立评估，本次保留现状

来源：[chasey 1b6fa75ca02aa7a7dd6d0b6c68865f16eef5ae0f](https://github.com/chasey-dev/immortalwrt-mt798x-rebase/commit/1b6fa75ca02aa7a7dd6d0b6c68865f16eef5ae0f)。驱动补丁已保存为 `chasey-fw-hdr.patch`，SHA-256 `8f42b33263f30a6998d92925d7c8adea35b1726ef26818dcfe7b42c1f3c874f5`；完整提交的文件改动已保存于 `chasey-fw-hdr-commit.json`。

对 prepared 源码 dry-run：`wlan_hwifi/Makefile` 和 `wlan_hwifi/config.mk` 均通过。该候选使用当前 20250613 SDK，不依赖新 SDK 或新 MAC 后端。完整改动需要同时带入 HWIFI package Makefile、Kconfig 和驱动 patch：配置跟踪、编译参数传递、MT7990/MT7992 header 生成条件不可遗漏。

本地实际情况：

- 现有 HWIFI Makefile 无条件定义 `CONFIG_HWIFI_FW_HDR_SUPPORT`；MT7993 的 `mt7993_fw_hdr_prepare()` 将固件来源设为 `HEADER_METHOD`。
- 上游新选项 `MTK_HWIFI_FW_HDR_SUPPORT` **默认 n**，因此直接采用上游默认值会改为 `request_firmware()` 从文件加载，不是无行为变化的整理。
- 既有 rootfs 已安装 MT7993 三个预期文件：ROM patch 12,576 字节、正常 WM 固件 1,151,516 字节、testmode 固件 1,238,556 字节；源码也具有 `BIN_METHOD` 文件加载分支。说明文件方式具备静态前提，但未核对数组与文件逐字节一致性、未重新编译、未测试早期启动和恢复重载。
- 若后续只引入开关并显式设 `CONFIG_MTK_HWIFI_FW_HDR_SUPPORT=y`，可保持既有嵌入来源；但这不带来关闭嵌入的模块体积收益，也不是驱动版本升级。
- 若后续设为 n，需确认最终镜像内三个文件可供模块首次初始化和恢复后重载；验证冷启动、Wi-Fi 重启、SER 后恢复及两频段连接。未完成前不声称内存减少幅度或性能提升。

因此本次 37.01 不改 FW_HDR。它适合作为单独对照构建候选，与新版 SDK 获取相互独立。文件大小/源码分支检查不能替代 MAX 实机稳定性验证。

## 可执行最小方案

1. 保留本次已核验的 8.3.1.2 主驱动、旧 HWIFI/OSAL/WARP 配套和 MAX Factory/SKU/MAC 路径。
2. 完成父任务已批准的 HNAT/QDMA/L2 小范围修复及本地编译，分别记录源码变更、构建和未做实机验证的边界。
3. 在 37.01 交付记录中明确：新版 Wi-Fi SDK 未取得、Wi-Fi SDK 未升级；WARP 缩环已存在；MAC/FW_HDR 本次未合入。
4. 新 SDK 待完整合法套件；FW_HDR 待单独验证。两者均不阻塞当前 HNAT 工作。
