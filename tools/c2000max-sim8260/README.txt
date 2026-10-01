SIM8260G-M2 识别与 RNDIS 拨号测试补丁 R3（2026-10-01）

R3 拨号修正
- 实机 NETACT=1 等待约 6 秒后返回 ERROR，30 秒等待仍无法激活。
- CGCONTRDP=1 显示当前运营商分配的实际 APN；所选 CID 6 的 APN 为空且没有活动记录。
- 自动 APN 时，仅给尚未激活的所选上下文继承当前 CID 1 的有效数据 APN。
  不硬编码手册中的 APN，不修改 UCI 的自动 APN 或用户指定的 CID。
- 保留已激活的所选上下文；不继承 IMS、SOS、emergency 或 V2X 专用 APN。
- NETACT 失败日志保存原始响应，区分 AT 返回 ERROR 与串口工具退出码。
- 专项诊断在恢复目标拨号后再检查主机联网，避免把暂停期间的断网误判为新故障。

安装脚本兼容性
- 兼容 OpenWrt 公共库中的可选变量，修复 IPKG_INSTROOT: parameter not set。
- 安装前型号查询最多等待 AT 队列锁 10 秒；失败时保持原配置。
- 归档文件时间戳归零，避免离线路由器时钟落后引起解压警告。

已确认的代码问题
1. 缺少 SIMCOM_SIM8260G-M2 型号条目；1e0e:9011 的 USB ID 兜底指向 A8200/ASR。
2. 原 SIMCom Qualcomm 流程设置 CNMP/CNWINFO，没有启用 NETACT 数据链路。
3. 拨号配置 CID 1、地址检查 CID 6，且原 SIMCom IPv6 正则可能误匹配 IPv4。
4. 基本信息按固定第二行取值，无法可靠处理回显、空行和带标签的返回。

补丁行为
- 为 SIMCOM_SIM8260G-M2 与无前缀别名添加 Qualcomm USB 配置。
- RNDIS 模式使用 AT+NETACT=1；停止拨号时使用 AT+NETACT=0。
- 默认建议 CID 6，依据用户提供手册第 341 页的 NETACT 示例；显式设置的 CID 保留。
  该示例不是所有定制固件都必须使用 CID 6 的保证，需要检查实际 CGDCONT/CGPADDR/QCMAP。
- 自动 APN 按上述 R3 规则处理；显式 APN 按用户设置定义所选上下文。
- 新型号按所选 CID 校验完整 IPv4/IPv6 地址，排除全零地址、错误 CID 和畸形地址。
- 此型号 RNDIS 概况的连接状态需要 NETACT=1 且数据 CID 有有效地址。
  Yes 仍表示模组数据上下文可用；路由器 DHCP、路由、DNS 和实际访问需另外验证。
- 型号与制造商解析兼容回显、空行及标签；固件版本优先 CGMR，失败后回退 SIMCOMATI。
  ATI 的 V1.0.01 与另一条查询的 22131B06X62M44A-M2 可能属于不同版本字段，不能直接认定后者错误。
- 不包含频段能力推测。QMI 列在模式配置中，当前实机验证目标是已枚举的 9011/RNDIS。

使用（将压缩包上传到路由器 /tmp）
此 R3 升级包适用于已经安装 SIM8260 R1/R2 补丁或 QModem r16 的设备。
安装脚本会校验文件版本；此前尚未安装 SIM8260 适配的旧设备需要对应的基础升级包。
tar -xzf /tmp/c2000max-sim8260-fix-r3-20261001.tar.gz -C /tmp
sh /tmp/c2000max-sim8260-fix-r3-20261001/diagnose.sh 2_1
sh /tmp/c2000max-sim8260-fix-r3-20261001/install.sh 2_1
等待约 20 秒，再执行 diagnose.sh，尝试联网。

请保留前后两个 /tmp/sim8260-diag-*.tar.gz 文件，供对比。
诊断脚本仅查询当前配置端口，不扫描其他串口，不重启服务；采集 IP、路由、USB、日志和只读 AT。
序列号字段会脱敏；诊断包不导出密码或完整 UCI 配置。完整配置备份仅存在路由器 /root 下。
安装会重新拨号，可能短暂断网；不主动执行模组重启、SIM 切换或 USB 模式切换。
安装脚本会核对硬件、原文件散列及 CGMM，避免覆盖其他版本或自定义改动。
如不是 qmodem.2_1，将命令中的 2_1 替换成实际 section。

回退：使用安装结束时显示的命令
sh /root/c2000max-sim8260-backup-<时间>-<PID>/rollback.sh /root/c2000max-sim8260-backup-<时间>-<PID>
回退恢复代码、支持表及备份时的 QModem 配置，并对目标模组重新拨号。

验证范围
已通过本地型号解析、拨号/停止、失败处理、运行时自动 APN 继承、活动上下文保留、CID/地址校验及现有模组回归测试。
尚未在用户这台 SIM8260G-M2 上验证成功联网；不能把本地测试等同实机成功。
此前 R2 镜像保持原样，此补丁尚未包含在 R2 镜像中。

手册：SIM82XX_SIM83XX Series AT Command Manual V1.03
相关章节：2.2.28/29（CGMM/CGMR），12.2.9（CUSBCFG），18.2.1（NETACT）。

专项激活诊断（NETACT 为 0、重复拨号仍无数据链路时）
将 probe_activation.sh 上传到路由器，执行：
sh /tmp/probe_activation.sh 2_1
脚本只暂停目标模组的拨号监控，保存原拨号日志和一次 NETACT 激活的原始响应、退出码与耗时。
本次单独把 NETACT 响应等待设为 30 秒，用于诊断，尚未将此值作为固件中的默认拨号超时。
同时采集 CGCONTRDP、CEER、CID 6 和 QCMAP 状态，再恢复目标模组拨号。
恢复拨号后等待 20 秒，确认监控进程运行后才采集主机联网状态。
脚本不写 APN、CID 或 USB 配置；运行期间移动网络可能短暂断开。
把输出路径中的 /tmp/sim8260-activation-*.txt 发回分析。

LAN IPv6 专项诊断（路由器 IPv6 可用、LAN 电脑取得地址但访问失败）
将 diagnose_ipv6.sh 上传到 /tmp，运行：
sh /tmp/diagnose_ipv6.sh 2_1 <电脑当前公网IPv6地址>
脚本只读取配置及网络状态，不发送 AT、不改 UCI、不重启服务。
记录网络/RA/DHCPv6/NDP 配置、前后路由/邻居/防火墙状态、路由器 WAN 与 LAN 源地址测试。
若 tcpdump 可用，在 LAN 和模组接口各捕获最多 40 秒、250 条 ICMPv6/DHCPv6 报文头。
开始捕获后同时在电脑运行默认源地址及指定源地址的 IPv6 ping。
电脑还应提供 Get-NetIPAddress 的 AddressState、PreferredLifetime、ValidLifetime，以及默认 IPv6 路由。
不要仅凭多个地址认定源地址错误：Deprecated 状态可正常保留，需要比较各源地址测试。
没有 PD 时，odhcpd 支持 RA/DHCPv6/NDP 中继；是否适用需结合当前上游前缀和回包诊断。
上游说明：https://github.com/openwrt/odhcpd/blob/master/README.md
Windows 地址状态：https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netipaddress
Windows 指定 ping 源地址：https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ping
输出 /tmp/sim8260-ipv6-*.tar.gz；可能包含局域网地址、设备名称和防火墙规则。
