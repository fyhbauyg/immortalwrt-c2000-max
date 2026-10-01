SIM8260G-M2 识别与 RNDIS 拨号测试补丁 R2（2026-10-01）

安装脚本 R2 修正
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
- 自动 APN 时保留已有数据上下文，不写入示例 APN；缺少所选 CID 时才定义该 CID。
- 新型号按所选 CID 校验完整 IPv4/IPv6 地址，排除全零地址、错误 CID 和畸形地址。
- 此型号 RNDIS 概况的连接状态需要 NETACT=1 且数据 CID 有有效地址。
  Yes 仍表示模组数据上下文可用；路由器 DHCP、路由、DNS 和实际访问需另外验证。
- 型号与制造商解析兼容回显、空行及标签；固件版本优先 CGMR，失败后回退 SIMCOMATI。
  ATI 的 V1.0.01 与另一条查询的 22131B06X62M44A-M2 可能属于不同版本字段，不能直接认定后者错误。
- 不包含频段能力推测。QMI 列在模式配置中，当前实机验证目标是已枚举的 9011/RNDIS。

使用（将压缩包上传到路由器 /tmp）
tar -xzf /tmp/c2000max-sim8260-fix-r2-20261001.tar.gz -C /tmp
sh /tmp/c2000max-sim8260-fix-r2-20261001/diagnose.sh 2_1
sh /tmp/c2000max-sim8260-fix-r2-20261001/install.sh 2_1
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
已通过本地型号解析、拨号/停止、失败处理、自动 APN 保留、CID/地址校验及现有模组回归测试。
尚未在用户这台 SIM8260G-M2 上验证成功联网；不能把本地测试等同实机成功。
此前 R2 镜像保持原样，此补丁尚未包含在 R2 镜像中。

手册：SIM82XX_SIM83XX Series AT Command Manual V1.03
相关章节：2.2.28/29（CGMM/CGMR），12.2.9（CUSBCFG），18.2.1（NETACT）。
