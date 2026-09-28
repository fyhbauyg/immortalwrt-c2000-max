# C2000MAX SRM825N / QModem 识别问题排查脚本

用于排查 **C2000MAX 新固件中 SRM825N 能被 `lsusb` 识别，但 QModem 无法识别/创建模组实例** 的问题。

## 使用方法

SSH 登录 C2000MAX 后执行：

```sh
wget -O /tmp/c2000max-srm825n-diag.sh \
  https://raw.githubusercontent.com/jasonBrom/immortalwrt-c2000-max/diag-srm825n-qmodem/tools/c2000max-srm825n-diag.sh

chmod +x /tmp/c2000max-srm825n-diag.sh
/tmp/c2000max-srm825n-diag.sh
```

脚本结束后会输出类似：

```text
/tmp/c2000max-srm825n-diag-YYYYMMDD-HHMMSS/report.txt
/tmp/c2000max-srm825n-diag-YYYYMMDD-HHMMSS/report-share.txt
/tmp/c2000max-srm825n-diag-YYYYMMDD-HHMMSS.tar.gz
```

优先让用户上传 **`report-share.txt`** 或整个压缩包。

## 采集内容

脚本主要采集：

- 系统与固件版本
- QModem / uqmi / umbim / USB / WWAN 相关软件包版本
- `lsusb`、`lsusb -t` 与 USB interface descriptor
- 每个 USB interface 当前绑定的 kernel driver
- `/dev/ttyUSB*`、`/dev/ttyACM*`、`/dev/cdc-wdm*`、`/dev/wwan*`、MHI 节点
- `option`、`usbserial`、`qmi_wwan`、`cdc_mbim`、`mhi`、`wwan` 等模块
- 与 USB / modem / QModem 相关的 `dmesg` 和 `logread`
- QModem 进程、procd 服务和 ubus 对象
- QModem 配置（密码/PIN/长数字会做基础脱敏）
- 系统中是否存在 SRM825 / SRM825N 适配代码
- USB hotplug 规则与驱动动态 ID 接口
- 网络接口对应的底层驱动

## 重点看什么

### 1. lsusb 有设备，但是完全没有 ttyUSB / cdc-wdm / wwan

通常先怀疑：

- USB composition 与现有驱动不匹配
- SRM825N 的 VID:PID 没有进入 `option` / `qmi_wwan` / `cdc_mbim` 对应 ID 表
- 某些 USB interface 显示 `driver=<none>`
- 对应 kmod 没有编译进固件

### 2. ttyUSB / cdc-wdm 已正常出现，但 QModem 不显示

通常更接近：

- QModem 没有 SRM825N profile
- QModem 的厂商/型号识别规则没有匹配 SRM825N
- hotplug 没有触发 QModem probe
- QModem 只扫描了固定 AT 口，SRM825N 的 AT 口编号与旧模组不同
- 新固件里的 QModem 包版本、依赖或启动顺序发生变化

### 3. AT 口存在，但数据口不存在

重点核对：

- `option` 是否只绑定了串口
- `qmi_wwan` / `cdc_mbim` / MHI 是否加载
- SRM825N 当前 USB composition 到底是 QMI、MBIM、ECM/NCM 还是其它模式

## 安全性

脚本默认只读：

- 不发送 AT 命令
- 不执行 USB unbind/rebind
- 不动态写入 `new_id`
- 不重启 QModem
- 不重启网络
- 不切换飞行模式

这样能尽量保留故障现场。

脚本同时生成 `report-share.txt`，会对 MAC、14~16 位连续数字和 USB serial 做基础脱敏。但在公开贴日志前仍建议人工快速检查一次。
