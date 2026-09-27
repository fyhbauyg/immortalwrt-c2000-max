# C2000MAX CPE Argon Theme

面向 C2000MAX V37.01 的 LuCI 主题。以该固件所用的 `luci-theme-argon` 为底座，加入离线打包的 daisyUI 组件样式和 Lucide SVG 图标。

## 页面与数据

- 登录后默认显示「状态 → CPE 首页」。LuCI 原有的「状态 → 概览」仍可单独打开。
- 侧栏使用 LuCI 的 `ui.menu` 动态菜单；已安装插件的分类与入口仍由固件菜单定义，不采用固定的演示导航。
- 首页通过 `system.board`、`system.info`、`network.interface.dump`、`luci-rpc.getWirelessDevices`、`network.device status`、`c2000max.sim_status`、`c2000max.hardware_status` 和 `qmodem.overview_info` 获取实时数据。插件未返回的字段显示 `—`。硬件接口返回的毫摄氏度会换算为摄氏度。
- 深色、浅色和跟随系统的控制位于页面顶栏及登录页，设置保存在浏览器本地。

## 预览

在本目录运行 `node demo/serve.mjs`，打开 `http://127.0.0.1:4174/demo/index.html` 和 `http://127.0.0.1:4174/demo/login.html`。演示首页运行与设备相同的 `home.js`，其 RPC 数据由 `demo/mock.js` 提供。

## 构建与安装

将本目录放入 V37.01 OpenWrt 构建树的 `package/custom/luci-theme-cpeargon`，启用 `CONFIG_PACKAGE_luci-theme-cpeargon=y`，执行 `make defconfig` 及 `make package/custom/luci-theme-cpeargon/compile V=s`。本包依赖 `luci-theme-argon`。

设备侧可用 `apk add --allow-untrusted luci-theme-cpeargon-2.0.4-r1.apk` 安装本地构建包。安装后 UCI 默认配置选择 `/luci-static/cpeargon`；卸载时回退到 Argon。

## 来源与许可

- Argon: Jerrykuku/luci-theme-argon，Apache-2.0。
- daisyUI: 5.6.6，MIT，已选取常用组件为本地 CSS；许可见 `DAISYUI-LICENSE`。
- Lucide: 1.8.0，ISC / 部分 Feather 图标 MIT；33 个图标构建为约 7 KB 的本地 SVG sprite。完整许可见 `LUCIDE-LICENSE`。需要重建图标时运行 `node tools/build-lucide.mjs PATH_TO_lucide/dist/esm/icons`。

安装包中的第三方许可放在 `/usr/share/licenses/luci-theme-cpeargon/`。
