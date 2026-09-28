# C2000MAX SRM825 / QModem 识别问题排查脚本

这个版本专门针对 **SRM825（不带 N）**。

适用场景：

- `lsusb` 已经能看到 SRM825
- 但 QModem 不显示模组
- 或者没有生成正确的 AT / QMI / MBIM / WWAN 设备
- 或者当前固件只适配了 SRM825N，没有适配 SRM825

## 使用方法

```sh
wget -O /tmp/c2000max-srm825-diag.sh \
  https://raw.githubusercontent.com/jasonBrom/immortalwrt-c2000-max/diag-srm825-qmodem/tools/c2000max-srm825-diag.sh

chmod +x /tmp/c2000max-srm825-diag.sh
/tmp/c2000max-srm825-diag.sh
```

执行完成后会生成：

```text
/tmp/c2000max-srm825-diag-YYYYMMDD-HHMMSS/report.txt
/tmp/c2000max-srm825-diag-YYYYMMDD-HHMMSS/report-share.txt
/tmp/c2000max-srm825-diag-YYYYMMDD-HHMMSS.tar.gz
```

建议用户优先上传 `report-share.txt`。

## 与 SRM825N 版本的区别

这个脚本除了常规 USB/QModem 检查外，还会分别检查：

- 是否存在 **精确 SRM825** 识别规则
- 是否只存在 **SRM825N** 识别规则
- QModem 的 modem profile 是否把 SRM825 与 SRM825N 当成不同型号
- SRM825 当前 USB interface 实际绑定到哪个内核驱动

如果日志出现：

```text
SRM825N rules exist
SRM825 exact rule missing
```

那么就很可能不是 USB 硬件问题，而是新固件中的 QModem 适配只覆盖了 SRM825N。

## 安全性

脚本默认不做任何主动修改：

- 不发送 AT
- 不写 USB `new_id`
- 不 unbind/rebind
- 不重启 QModem
- 不重启网络
- 不切换 USB composition
