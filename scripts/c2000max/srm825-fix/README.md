# SRM825 不识别修复（2026-09-28）

## 已确认的问题

诊断包记录 USB ID `2dee:4d23`，option 已生成 ttyUSB0～4，cdc_ether 已生成 usb0，网卡属于 USB 接口 1.5。扫描器连续报告 `slot=2-1 type=usb has no net device yet` 后放弃。

旧扫描器将 `modem_port_rule.json` 中的 `include: ["1.1"]` 应用于所有 USB 接口，把 ECM 网卡接口 1.5 过滤掉，因而没有进入 AT 验证。现有支持库已经包含无 N 后缀的 `srm825`。

## 给使用旧固件的用户

将整个修复包上传到路由器 `/tmp`，在路由器 SSH 中执行：

```sh
tar -xzf /tmp/C2000MAX-SRM825-ECM-fix.tar.gz -C /tmp
sh /tmp/srm825-fix/fix-srm825-ecm.sh
```

脚本会核对 USB ID、ECM 驱动和接口 1.5，备份原规则，只为该设备加入 1.5，重启 QModem 扫描服务并重新扫描。会重新进行模组探测和拨号；无需改 USB 模式、换驱动或重启路由器。**只在出现该故障的 SRM825 路由器上执行。**

等待约 30～60 秒后检查 QModem，并执行：

```sh
logread | grep -E 'modem_scand.*(2-1|added modem|profile|AT port)' | tail -30
uci -q get qmodem.2_1.network
uci -q get qmodem.2_1.name
uci -q get qmodem.2_1.at_port
```

预期不再报没有网卡，network 包含 usb0。型号和 AT 端口以实际探测结果为准。确认 SIM、注册和拨号正常后，再验证上网。

如果仍失败，请回传上述输出。若出现 `no valid AT port` 或 `profile not matched`，这是修复网卡发现后显露的下一环节，需实际 AT 返回值继续定位。

## 回退

脚本会输出备份文件的完整路径。将该备份复制回 `/usr/share/qmodem/modem_port_rule.json`，再执行 `/etc/init.d/qmodem_init restart`。不要删除其他模组配置。

## 新固件的正式修复

`modem_scan 3.1.2-r2` 将 include 规则限定为 AT 端口筛选；已绑定的 ECM/RNDIS/QMI/MBIM/NCM 网络接口独立发现。无需旧版 JSON 临时补丁。

已用诊断中的 USB 拓扑复现旧版漏检，并对修复后的实际 C 扫描函数做了回归测试，确认网卡可发现、AT 白名单和设备隔离仍生效。诊断包没有 AT 查询结果，当前也没有故障 SRM825 实机，因此尚不能宣称该用户已恢复注册、拨号或上网。
