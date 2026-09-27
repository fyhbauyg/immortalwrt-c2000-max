# C2000MAX UI · OpenWrt / LuCI 主题

将已确认的 C2000MAX 首页、组件库与设计规范接入 LuCI 的独立主题包。深色为黑灰底色，图标保留分类色；支持浅色、深色、跟随系统和手机抽屉菜单。

## 交付内容

- 安装包：`build/luci-theme-c2000max-ui-1.0.1-r2.apk`，针对现有 V37.01 构建树编译。
- 登录页：居中窗口、Bing 每日壁纸、密码显示切换、LuCI 原生认证与 HTTPS 探测。
- 首页：C2000MAX 正视图、5G 信号/频段/聚合、内存/缓存/RootFS/SWAP、模组信息和温度。
- 真实路由：Wi-Fi → `admin/network/wireless`；查看模组详情 → `admin/modem/qmodem`。
- LuCI 适配：导航、路由页签、表单、校验、表格、动态列表、下拉框、文件选择、提示、弹窗、进度、接口/防火墙区域、保存/应用。
- 手机端：完整可搜索菜单、底部快捷入口、紧凑外观切换、单列表单和可横向滚动表格。

已在 192.168.66.1（ImmortalWrt 25.12-SNAPSHOT / NRadio C2000-MAX）安装验证。无线与网络配置仅检查显示，未修改实际设置。

## 安装与启用

适用于当前基于 ucode 模板的 LuCI / APK 固件。当前验证构建树 commit：
`876a467f7bf9dc0790c6783637a8d621e5bd7c81`。旧版 Lua 模板固件需另做移植。

将 APK 上传到设备的 /tmp，在设备上运行：

```sh
apk add --allow-untrusted /tmp/luci-theme-c2000max-ui-1.0.1-r2.apk
```

安装只注册新主题，不会覆盖 Argon、CPE37 或原 C2000MAX 主题。打开 **系统 → 系统 → 语言和界面**，选择 **C2000MAX_UI**，保存并应用后刷新。

也可手动启用：

```sh
uci set luci.main.mediaurlbase='/luci-static/c2000max-ui'
uci commit luci
/etc/init.d/rpcd reload
```

新首页：`/cgi-bin/luci/admin/status/c2000max`。该菜单只在启用本主题时出现，并排在状态分类首位；原 LuCI 概览仍然保留。

### 切回现有主题

在界面中选择原主题，或：

```sh
uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci commit luci
/etc/init.d/rpcd reload
```

卸载使用 `apk del luci-theme-c2000max-ui`；若当前正在使用本主题，卸载脚本会恢复 Bootstrap。不会删除其他主题、QModem 配置或无线设置。

## 数据接入

详见 [INTEGRATION.md](docs/INTEGRATION.md)。

首页只读，系统与 QModem 缓存每 10 秒刷新，MTK 无线状态和温度每 20 秒刷新，SIM 插件每 60 秒查询一次。系统数据和可选插件独立更新；一个接口失败不会阻塞其他卡片。不启动拨号、不切换 SIM、不写无线配置、不直接发送 AT 命令。

QModem 的信号、模组温度和 SIM 信息来自插件已有缓存；信号超过 120 秒会隐藏旧数值并提示刷新。若插件尚未生成缓存，需要先打开 QModem 页面获取。主题没有伪造实时值，也没有额外启动 AT 轮询器。

CPU / Wi-Fi 温度优先来自 `c2000max.hardware_status`；MTK 驱动的 Wi-Fi 温度补充读取固定 ra0/rai0 接口的 `mwctl stat`。该接口未提供告警阈值，因此默认显示“待评估”，不会擅自判定正常。可在 `/etc/config/c2000max_ui` 中配置设备适用的 `cpu_warning`、`cpu_critical`、`wifi_warning`、`wifi_critical`（°C）；配置后自动显示正常/偏高/过高。

多个模组默认选第一个启用的 `qmodem.modem-device`；可将 `c2000max_ui.main.modem_section` 改为指定配置节名。

## Bing 每日壁纸

- `c2000max-wallpaper` 服务每 15 分钟检查本地日期，同一天成功后不再下载。
- 使用 Bing 官方图片接口，优先 cn.bing.com，失败再尝试 www.bing.com；保留 TLS 证书验证。
- 图片和元数据放在 `/tmp/c2000max-ui`，不反复写入闪存；成功下载后原子替换缓存。
- 登录请求只读取缓存，不等待联网。下载失败继续使用已有图片；首次离线使用渐变背景。
- 登录页展示 Bing 图片署名，公共图片端点只返回这一个缓存文件。
- 可运行 `/usr/libexec/c2000max-bing` 检查当日缓存；服务状态：`/etc/init.d/c2000max-wallpaper status`。

## 设计与组件

- [设计规范](docs/DESIGN-SYSTEM.md)：颜色、字体、间距、响应式及交互规范。
- [Argon 组件审计](docs/ARGON-COMPONENT-AUDIT.md)：上游组件及来源映射。
- [LuCI 实装映射](docs/THEME-COMPONENTS.md)：组件规范如何作用于真实 LuCI。
- 现有可交互组件库保留在 `../luci-theme-cpe37/demo/soft-ui/components.html`；未将演示逻辑打入固件。

## 构建与验证

```sh
# OpenWrt SDK/构建树：复制整个目录到 package/custom 后
make menuconfig
# LuCI → Themes → luci-theme-c2000max-ui 选择 M
make package/custom/luci-theme-c2000max-ui/compile V=s
```

本工作区使用 `tools/build-local.sh` 编译单个包并校验原 .config 不变。Windows 源码不保存 Unix 执行权限，该脚本会为 init、CGI、壁纸脚本和 uci-defaults 设置 0755；移植到其他构建树时也要保留这些权限。

测试：

```sh
node tests/data.test.cjs
# 当前 WSL 构建环境，使用同版本原生 ucode：
bash tools/build-validator.sh
bash tools/validate-templates.sh
# 本机浏览器预览（需要现有 Playwright / Edge）：
node tools/preview.cjs
node tests/browser.test.cjs
```

本地预览 `http://127.0.0.1:4179/`，登录预览 `/login`，LuCI 表单外观预览 `/forms`。预览数据与模拟运行时仅在 tests/build 下，未包含在 APK 中；预览页不执行登录或配置写入。


## 1.0.1 真机适配

- 兼容华为模组的 MMC 字段，内置移动、联通、电信图标；其他运营商显示名称。
- SIM 卡槽使用 C2000MAX SIM 插件的 current_slot（每 60 秒，只读查询，不切卡）。
- 已驻留 NR 主频段但无 CA 记录时显示 1 CA；无主频段或缓存过期仍显示未获取。
- 按用户指定组合显示 5G-A：电信/联通 n78+n78；移动/广电 n41+n41+n79。这是界面标记规则，不是网络能力认证。
- 无线状态通过设备端 ubus 读取并仅返回 SSID/启用状态；调用失败不显示成全部关闭。
- 桌面宽度 >1100px 首页内容 zoom:0.9，侧栏与手机页面不缩放。
- 原生表单紧凑按钮、完整无线操作布局、下拉框、页签、居中进度值与刷新图标。
