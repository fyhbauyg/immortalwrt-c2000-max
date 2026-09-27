# CPE37 主题 · C2000MAX V37.01

这是依据用户提供的 `openwrt-cpe-theme-&-dashboard.zip` 页面视觉重新实现的 LuCI 主题包。参考稿里的速率、模组和终端数据是模拟值；本包不会使用这些值。主题使用 37.01 现有 LuCI Bootstrap 作为底层表单样式，页面采用参考稿的灰白/深色、蓝色强调、圆角卡片与移动底栏。

概况读取 `system.info`、`system.board`、`network.interface dump`、`network.device status` 和 QModem 的 `overview_info`。QModem 无模组或无状态时显示空值及提示，不编造数据。原始 LuCI 状态页保留在折叠区。完整分类和插件菜单仍由 LuCI 的菜单树生成，安装插件后自动显示；菜单中的功能受其自身 ACL 约束。

移动底栏：**总览 / 5G模组 / 无线 / 菜单 / 退出**。5G 模组链接 `/admin/modem/qmodem`，无线链接 `/admin/network/wireless`，退出链接 `/admin/logout`。菜单按钮打开可滚动的完整 LuCI 分类列表。

## 37.01 构建

将本目录放在构建树 `package/custom/luci-theme-cpe37`，在 `.config` 启用 `CONFIG_PACKAGE_luci-theme-cpe37=y`，执行 `make defconfig` 和 `make package/custom/luci-theme-cpe37/compile V=s`。安装 APK 后默认启用 CPE37。可在 LuCI 语言与界面设置中切回其他主题。

主题不改变 QModem、无线、网络或其他插件的业务逻辑；其详情页仍使用原有 LuCI 页面。新主题包独立于工作区中的其他自定义主题。

已编译的 37.01 APK 位于 `dist/luci-theme-cpe37-1.0.0-r1.apk`，校验值见 `dist/SHA256SUMS`。`demo/index.html` 与两张截图只用于视觉预览，图中的运行时间是示意内容；正式主题使用 RPC 读取设备实际状态。本次已验证 JS 语法、桌面和窄屏静态布局、37.01 APK 构建与包内容；尚未在实体设备上安装运行。
