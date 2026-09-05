# C2000MAX v36.5：5G NR 上行低延迟 QoS（实验性）

入口：网络 → 5G NR 低延迟 QoS，`/cgi-bin/luci/admin/network/c2000max-nrqos`。

## 使用范围

这是参考 QoSmate 的队列管理与多探针调速思路实现的独立、小型上行控制器，不是将 QoSmate 改名打包，也不是 MTK 硬件 HQoS。它给 USB NCM `eth2` 挂 CAKE `besteffort flows nonat`，不改 HNAT / HQoS 开关、PPE、路由、nft/conntrack mark 或官方 Flash。默认关闭，原 SQM/HNAT 安全互斥保持不变。

首版仅支持主要 IPv4 默认路由为 USB NCM `eth2` 的 5G 上行。WAN、双 WAN 的完整覆盖和下行整形不在本次支持范围。`flows nonat` 是流公平，不是按 NAT 前 LAN 设备公平；不提供游戏设备或全 UDP 强制提权。基站调度、弱信号、运营商路由造成的延迟无法靠本地 QoS 消除。

## 参数与启停

- UCI：`/etc/config/c2000max_nrqos`，`config main 'main'`。
- 服务：`/etc/init.d/c2000max-nrqos`。保存并应用会重启监督进程；状态明确区分已配置启用与队列实际运行。
- `enabled=0`、`autorate=0`。按本次用户通常上行约 150 Mbps，初始 `upload_kbit=130000`（130 Mbps）；这是试验起点，不是实测保底值或通用推荐。
- 先测繁忙时稳定上行，再填写低于其容量的固定上限。`min_upload_kbit`、`max_upload_kbit` 默认 0，启用自适应必须填写，满足 `128 ≤ min ≤ upload ≤ max ≤ 1000000`，单位 kbit/s。
- 自适应使用 2–3 个不同 IPv4 探针、各自 RTT 基线、共同延迟抬升、负载门槛和连续窗口；异常降速 10%，稳定后缓慢提高 2%，丢失探针时冻结。默认探针只是候选，应验证在本运营商线路上的稳定性。
- 会话内 RTT 基线只向下更新，避免把持续拥塞学为正常；服务重启或链路重连后重新学习。已通过连续 100 轮低负载、高 RTT 的基线不漂移回归。
- 当前保守算法在负载低于设定上限的 70% 时不降速，避免误把普通 5G 抖动当拥塞；因此**不保证捕捉所有 NR 突降容量场景**，尤其 TCP 先退让导致观察负载也下降时。自适应仍需进一步受控验证。
- 关闭时仅删除自身 `365:` 根队列，让内核恢复自动 fq_codel；不覆盖别的插件队列。重复启动、旧会话延迟退出、PID 复用、设备丢失、默认路由切走都有所有权/退出保护。
- 活动 SQM、设备 EQoS、QoSmate 或非默认根队列会被拒绝接管。启用 SQM 前先同步停用 NR 队列，保留原有 SQM 关闭 HNAT 的保护。

## 实现边界

当前 prepared 6.12.94 内核的 `do_hnat_ge_to_ext()` 经 `dev_queue_xmit()` 进入 eth2 egress/root qdisc，但该路径早于 conntrack/mangle 消费包，不能依赖普通 nft forward 的 mark 为每个硬件包分类。当前不改任何 mark，也不复制可能覆盖 MWAN3 标记的规则。

CAKE 使用 `no-split-gso`，避免引入新的提前分段路径；大 GSO 包在较低限速时可能带来额外突发，后续需以实测决定是否在限定 eth2 出口开启 split-gso。下行 IFB 有首包学习重入和计数风险，本版没有安装。

## 2026-09-05 验证记录

已通过后端生命周期/队列所有权/配置边界/插件冲突/并发会话/PID 复用/自适应滞回测试、LuCI 表单 mock 测试，以及 v36.5 官方 SPI 写保护、端口模式、低内存服务回归。尚未在实机浏览器验证新页面的全部主题交互。

实机测试只在 `/tmp/c2000max-nrqos-test-20260905` 放程序与独立 UCI 配置；未修改 `/etc/config`，未刷机，未写 MTD/bootenv。PC 绑定有线 `192.168.66.142`，两次各上传 16 MiB 生成的零数据到公开 Cloudflare 测速端点，没有上传用户文件。

- 原始队列：fq_codel，HNAT enabled；临时队列：CAKE 20 Mbps，HNAT 仍 enabled，HQoS 仍 disabled。
- 原始请求约 28.22 Mbps，临时请求约 7.99 Mbps；公网单流结果波动明显，**不能把这两个值当作 NR 150 Mbps 容量验证或延迟改善证明**。
- 12:41:40→12:41:43，eth2 TX 从 98,364,106 增至 100,946,051 字节；CAKE Sent 从 8,810,111 增至 11,392,056 字节，差值均为 2,581,945 字节。
- 下一窗口至 12:41:47，二者差值又同为 3,345,406 字节，确认这些上行发送经过该队列。
- 目标连接下行 PPE0 BIND 字节 96,762→122,412→158,372，持续增长；PPE1 上行没有捕获到 BIND，**尚未证明上行硬件绑定与整形共存**。状态保留 `dataplane_verified=false`。
- 12:43:17 两分钟回退执行成功，恢复原 handle 0 fq_codel；HNAT/HQoS 与测试前一致，eth2 RX/TX errors 均为 0。SPI 暴露分区 flags 仍全部为 `0x800`（只读）。

下一验收应使用可控上传服务器和稳定长连接，在 130 Mbps 附近同时测队列覆盖、目标上行 BIND/MIB、CPU/softirq、空载/满载 RTT p50/p95/p99、丢包，并验证 NR 容量突降和恢复。未完成这些测试前不默认启用、不标记为完整双向硬件 QoS。

参考来源：[QoSmate](https://github.com/hudra0/qosmate)、[cake-autorate](https://github.com/lynxthecat/cake-autorate)、[Cloudflare 测速端点](https://github.com/cloudflare/speedtest)。
