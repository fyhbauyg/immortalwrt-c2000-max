# C2000MAX LuCI 主题（V37.01）

面向 C2000MAX 的轻量 LuCI 主题源码。视觉上使用蓝绿 CPE 状态语言、浅色/深色/跟随系统三种模式、移动端抽屉导航和本地 daisyUI 组件样式。LuCI「状态 → 概况」会显示与 Demo 同风格的实机仪表盘，数据来自当前状态页和设备 RPC；原始状态信息可以在下方展开。其他 LuCI 页面、CBI 表单、提示、弹窗与操作行为继续可用。

## 预览

在本目录的上级目录执行：

```sh
node luci-theme-c2000max/demo/serve.mjs
```

浏览器访问 `http://127.0.0.1:4173/demo/index.html`。Demo 的信号、SIM、速率、流量与设备值是**示例数据**，用于审查视觉设计；它不会连接路由器或更改设置。`/demo/login-preview.html` 是登录页视觉预览，表单不可提交。

## 插件菜单兼容

正式主题模板中的 `#modemenu`、`#topmenu`、`#tabmenu` 由 LuCI 自带的 `menu-bootstrap` 从当前菜单树生成。**没有写死分类或插件名单**。安装的 LuCI 插件只要正确提供 `menu.d` 定义且当前用户拥有 ACL 权限，就会进入其菜单分类。主题脚本只给分类加图标、标记当前项、提供搜索和手机抽屉；未知分类使用通用图标。搜索清空后恢复全部菜单项。

可访问 `http://127.0.0.1:4173/demo/menu-fixture.html` 查看异步加入的 `Services`、`QModem`、`OpenClash` 和自定义插件分类；这个页面只用于菜单兼容检查。插件更深层的页面继续由 LuCI 的 `#tabmenu` 显示。

## 接入 37.01 构建树

1. 将整个 `luci-theme-c2000max` 目录复制到 37.01 源码的 `package/custom/` 下。构建树须已准备好现有 `feeds/luci`；无需更新或覆盖 LuCI feed。
2. 将 `CONFIG_PACKAGE_luci-theme-c2000max=y` 加入 `.config`，执行 `make defconfig`、`make package/custom/luci-theme-c2000max/compile V=s`。
3. 安装生成的包后，在 LuCI「系统 → 语言和界面」选择 `C2000MAX`。也可用 `uci set luci.main.mediaurlbase='/luci-static/c2000max'; uci commit luci` 切换。

本工作区的 V37.01 `build.config` 使用 `CONFIG_USE_APK=y`。本主题已在对应的 `aarch64_cortex-a53` 构建树中编译为 APK，并在实体 C2000MAX V37.01 上安装验证。原有 Argon 和 Bootstrap 保留作为回退。

## 大小和资源

- 只打包本地样式、SVG 和 JS，不依赖 CDN。
- daisyUI 5.6.6 官方 npm 包经 SHA-256 校验，由 `node build-daisy.mjs` 提取主题使用的 `button`、`menu`、`card`、`badge`、`alert`、`input`、`navbar` 组件及基础样式。生成的 CSS 为约 177 KB，完整版本约 1.08 MB。
- daisyUI 使用 MIT 许可证，详见 `DAISYUI-LICENSE`；LuCI Bootstrap 兼容模板使用 Apache-2.0。

## 当前边界

主题改变 LuCI 外观和导航，不修改或替代任何插件功能。实机仪表盘读取 LuCI 总览已有的模组、信号、无线、系统、DHCP 租约数据，并通过 `network.device status` 读取 WAN 接口字节计数器计算实时速率。DHCP 租约不等同于在线连接，因此卡片标为「设备与租约」；Wi-Fi 终端数来自关联数。原有 LuCI 总览完整保留在「查看完整设备详情与原始状态信息」折叠区。不同插件版本若调整状态页字段，相关卡片会显示「—」，原始页和插件入口仍可使用。

## 实机验证

在 C2000MAX V37.01 上验证了 APK 安装、主题切换、登录模板响应、浅色/深色模式、390px/701px/1440px 页面宽度、真实速率曲线、原有状态页展开、QModem 页面及动态菜单。设备菜单实际显示了 QModem、OpenClash、PassWall 2 等插件。测试未更改设备网络、无线或模组配置。
