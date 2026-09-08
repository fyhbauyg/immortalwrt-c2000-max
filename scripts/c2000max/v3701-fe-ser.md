# V37.01 FE/SER 与可选 HNAT 早绑定独立评估

核查日期：2026-09-08。状态：只读源码评估；未修改 WSL 仓库，未运行 make，未接触设备，未执行实机测试。

## 结论

| 候选 | 原始文件 / 全部补丁 / prepared kernel | 建议 |
|---|---|---|
| MediaTek 13c73de：FE miscellaneous IRQ 与复位事件计数 | 未包含，也未发现等效实现；已有 SER 框架和 MT7987 DTS 中断资源不是此更新的等效修复 | 保留独立阶段，本次 P1 镜像不纳入 |
| MediaTek 739b12e：阈值 <= 1 时 HIT_UNBIND 允许早绑定 | 未包含；原始与展开代码默认硬件阈值均为 30，没有软件阈值字段/ready-bind helper | 可选项延后，不修改阈值或默认行为 |

以上是适用性和集成风险判断，不能证明当前设备遇到过 FE 异常，也不能证明任何更新改善网页访问、无线峰值或时延。

## 固定基线和证据范围

- 仓库：WSL Ubuntu-24.04，用户 wkz，/home/wkz/c2000max-v36.01-build。
- 只读核查时分支：37.01；HEAD：763b31f97c72d20376d1ab4b7650651f4a706e2d。
- git status 未发现已跟踪文件修改；已有多组 c2000max-artifacts-*、.verify-interlock-root.squashfs 和 LuCI 生成文件等未跟踪内容，全部保持原样。
- find 仓库未发现 AGENTS.md。已完整读取用户交接 MD。
- 原始厂商 HNAT：target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/。
- 全部目标补丁：target/linux/mediatek/patches-6.12/，按内容搜索而非按提交 SHA 判定。
- 最终内核：build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/linux-6.12.94/，下称 K/。这是本轮改动前已有展开结果，未重新 prepare。
- 另核对 toolchain 内 Linux 原始 Ethernet 源码，不含 misc IRQ/counter 实现；以 K/ 为最终行为证据。
- K/.config：CONFIG_MEDIATEK_NETSYS_V3=y、CONFIG_NET_MEDIATEK_HNAT=m、CONFIG_NET_MEDIATEK_SOC_WED=y、CONFIG_NF_CONNTRACK_MARK=y。
- 官方两个完整 commit patch 已从 mediatek 官方 GitHub 读取，并保存为本目录 upstream-* 文件。没有覆盖上游或本地驱动目录。

## FE/SER：确定缺口与完整依赖

官方来源：[13c73de25ef3f53f5dabdc2f2b410f3aaccbcd0d](https://github.com/mediatek/mtk-openwrt-feeds/commit/13c73de25ef3f53f5dabdc2f2b410f3aaccbcd0d)。

该提交改动五个补丁文件，不能直接套官方仓库根目录 diff：

1. 通用 eth-54 新增 misc 中断源分组、enable/ACK、handler、第四 FE IRQ 登记、事件枚举及 IRQ 容量。
2. 通用 eth-90 添加 reset_event 计数接口与各恢复入口的计数更新；提供 reset.count[32] 与 mtk_reset_event_update，handler 在最终补丁状态调用它。
3. Logan eth-93 将计数与现有内部 SER notifier 整合。必须保留 START_RESET、STOP_TRAFFIC、RESET_NAT_DONE 及 Wi-Fi 完成通知。
4. Logan eth-91 为 HNAT 接口补丁的上下文刷新，当前提交没有新增 HNAT 行为。
5. 通用 wed-13 为已有 WDMA disable/enable 补丁刷新上下文，当前提交没有升级 proprietary WARP 核心，不可当作 Wi-Fi SDK 更新。

本地实际差异：

- K/drivers/net/ethernet/mediatek/mtk_eth_soc.h:118 仍为 MTK_FE_IRQ_NUM (3)，1731 附近为 irq[3] / irq_fe[MTK_FE_IRQ_NUM]；没有 upstream 已采用的 MTK_FE_IRQ_SHARED/TX/RX 常量布局，因此 eth-54 的头文件 hunk 不能原样套用。
- K/ 同目录 mtk_eth_soc.c:7346 的资源读取循环只取 3 路 FE IRQ；7440 附近只登记 FE TX 与 PDMA RX；没有 mtk_handle_irq_misc。
- K/ 同目录 mtk_eth_soc.c:5680 附近仍写固定 FE_INT_GRP 0x210FFFF2；没有为 misc 配置 IRQ3、使能六种异常源。
- 没有 mtk_reset_event_name、MTK_EVENT_* 计数枚举、reset.count[32] 或 reset_event 文件实现。补丁目录的旧 PROCREG_RESET_EVENT 宏若出现，不能视为功能已实现。

### MT7987B IRQ/DTS 对照

K/arch/arm64/boot/dts/mediatek/mt7987-netsys.dtsi:20 的 Ethernet 节点已有八路中断：

| platform IRQ 索引 | 资源 | 当前用途 |
|---|---|---|
| 0..3 | GIC SPI 189、190、191、192 | PDMA IRQ0..3 |
| 4 | GIC SPI 196 | FE IRQ0 |
| 5 | GIC SPI 197 | FE IRQ1 / TX |
| 6 | GIC SPI 198 | FE IRQ2，HNAT flow-check IRQ |
| 7 | GIC SPI 199 | FE IRQ3，拟供新增 misc handler |

同一 DTS 的 hnat 节点使用 SPI198；5119 的 flow-check IRQ handler 管理的是 FE_INT_STATUS2/ENABLE2，不是新增 misc 的 STATUS/ENABLE，二者不能合并或复用 IRQ2。

MAX DTS includes mt7987b.dtsi -> mt7987a.dtsi -> mt7987-netsys.dtsi；MAX 的 &eth 仅将状态设为 okay，没有覆写 IRQ。现有 DTS 已提供第四 FE IRQ，无需凭空增加中断，实际映射仍须在生成 DTB 和实机核对。

若适配，IRQ 读取个数可依据已验证的 SoC/capability 选择；数组必须固定最大容量，不能把依赖局部 eth 变量的表达式用于结构体数组。需要确保老平台仍读取三路，新平台读取四路，且不改动 HNAT SPI198 的归属。

### 5119 生命周期与 SER 恢复

K/mtk_hnat/hnat_nf_hook.c:731..918 保留 ready/removing/quiescing 闸门；只在 MTK_FE_RESET_NAT_DONE 调用 hnat_warm_init。K/mtk_hnat/hnat.c:2069 起的 warm init：

- 在 lifecycle_lock 内关闭 ready、设置 quiescing、停 flow IRQ、同步停止两个定时器；
- 撤销 hook、packet/notifier/headroom 等入口并等 RCU/network 读者退出；
- 刷新 per-flow kick workqueue；
- 清 FOE/MIB/统计状态，逐 PPE 重设硬件，然后恢复注册入口、计时和 hooks；
- 保留错误路径及不可恢复状态，不能替回原始未保护 warm_init。

K/mtk_eth_soc.c:6022..6145 的现有 pending_work 会先准备复位、通知 Wi-Fi，再执行 warm reset / 启动 DMA，最后发送 RESET_NAT_DONE。MAX 的 5119 warm-init 保护在这个末尾通知才进入，因此它本身不证明较早的整个 FE/Wi-Fi 复位窗口安全。应单独验证前后入口关闭、RXPPD、外部设备引用与 HNAT 表状态。

需要明确处理的风险：

1. 官方新增 misc handler 不写 eth->reset.event，只 ACK、计数和排队。当前 STOP_TRAFFIC 路径会留下 reset.event，完成后未统一清回 START_RESET。若之前执行过 stop/start，后续 misc 事件可能继承该通知语义。应明确并论证 misc 各异常使用完整重置还是 stop/start，而非盲目追加 schedule_work。
2. 当前 probe 中 reset.force 初值为 0（K/mtk_eth_soc.c:7248）。官方 handler 受该值控制。因此仅合入 IRQ 不等于默认开启自动 SER；不可顺便改默认值，也不可声称自动恢复已启用。
3. 现有恢复过程中等待 Wi-Fi completion/ack；不能把出现 reset done 日志或编译成功作为接口、PPE、Wi-Fi 重绑定成功的证据。
4. 新 IRQ 是新的异步 pending_work 生产者。原有 remove/deinit 先关时钟、清设备，cleanup 较后才 cancel 工作，官方新 patch 未增加显式 misc mask/synchronize。独立适配应审视 probe 失败、remove、reset 等路径的 IRQ 与 work 销毁顺序，保留已有 HNAT supplier/lifecycle 约束。
5. 上游事件计数为普通 u32 增量和 debugfs memset 清零，不是严格并发统计。可作诊断提示，不宜用作精确事件总量或恢复成功判据。

以上问题需要源码设计和测试一起收敛。本轮没有删除保护、吞错误或为编译而改通知顺序；也没有提供/执行触发硬件 reset 的命令。

## 可选早绑定：缺口及 OAF 关系

官方来源：[739b12eefe2926b2826d538d3a14f0155f2a273a](https://github.com/mediatek/mtk-openwrt-feeds/commit/739b12eefe2926b2826d538d3a14f0155f2a273a)。

原始 hnat.c:1152 和 K/mtk_hnat/hnat.c:1403 都仍设 BIND_RATE=0x1E；原始/补丁/最终文件未发现 bind_threshold、DEF_BIND_THRESHOLD、CFG_PPE_BIND_THRESHOLD 或 skb_hnat_reason_ready_bind。实际缺失已经确认。

若后续选择移植，成套范围为：

- hnat.h：默认 30、每设备 u16 软件阈值状态、读取辅助接口；
- hnat.c：probe 在硬件初始化前初始化状态，hnat_hw_init（含 warm reset 调用）使用存储阈值；
- hnat_debugfs.c：保留 5104 的 0..65535 检查与 BIND_RATE 字段写入，保留 5119 的 lifecycle_trylock / ready / PPE started 过滤，软件状态与写入语义一致；
- nf_hnat_mtk.h：判定 RATE_REACH 或低阈值 HIT_UNBIND，且访问遵守当前 hnat_priv 生命周期；
- hnat_nf_hook.c 六处：464XLAT pre-process、桥接 flooding check、Wi-Fi deferred TX bind、464XLAT post-process、post-routing HIT_UNBIND case、IPv6 local-out/MAP-E；
- 464XLAT 保存的 descriptor reason 判定不能遗漏。仅修改 post-routing 一处，会留下不同路径不一致。
- 并发读取阈值应结合当前锁与 READ_ONCE/WRITE_ONCE 规范；不能把上游原始 writel(threshold, PPE_BNDR) 带回来。不要改变默认阈值。

OAF 证据与要求：

- K/mtk_hnat/hnat_nf_hook.c:4787 在 post-routing 检查 skb HNAT_EXCEPTION_TAG；3039..3049 在 skb_to_hnat_info 前段检查 ct->mark，同步记 admission_denied。
- package/mtk/applications/c2000max-appfilter/src/oaf/app_filter.c:3416 起用 ct->lock 维护单流 no-offload bit；4230 起 CLASSIFY_PENDING 对 handshake/ACK-only 同样保留 hold。seamless 模式有意允许加速，balanced/precise 会 hold。
- 6003 保留按 conntrack tuple 清单流以及 warm reset 时冲刷 pending kick work，不应退回全局表冲刷。
- 早绑定仍必须走现有 skb/ct 门禁。不能将 HIT_UNBIND 直接跳到最终 BIND、跳过 skb_to_hnat_info、flooding/FDB、外部接口或生命周期判定。
- mtk_sw_nat_hook_tx 消费先前准备的 flow_entry；新增早绑定意味着更早触达此路径，需要验证 hold 发布、释放、动态 BLOCK 与已准备但未最终提交的 entry 的关系，而非假设默认阈值下的表现适用于阈值 0/1。

建议暂不纳入：默认 30 不会激活新早绑定分支，本次没有低阈值零丢包测试需求；它也不是已证实的网页/游戏延迟修复。保留为明确启用场景下的独立可选更新。

## 后续独立阶段的验收范围

- FE：完整补丁展开、MT7987 DTB IRQ 索引、Ethernet/HNAT 同时编译，再验证冷启、加速启停、Wi-Fi 与外部模组流量、拓扑变更，以及可恢复测试设备上的 SER 后接口/PPE/OAF/MIB/HQoS 恢复。
- 早绑定：保持阈值 30 做对照；另测 0/1 的实际 HIT_UNBIND、RATE_REACH 与 BIND 时序，覆盖 IPv4/IPv6、L2 bridge flooding、Wi-Fi deferred TX、464XLAT/MAP-E 以及 OAF hold/block/release。
- 所有实机项：未测。本报告不是适配完成、编译完成或设备稳定性声明。
