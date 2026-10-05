# Argon → C2000 UI：组件审计

审计日期：2026-09-26。此清单用于主题设计与页面适配，覆盖 **30 个组件族、6 个功能分组**，不是对全部第三方插件的兼容承诺。

## 源码基线

| 范围 | 版本 / 固定提交 | 本轮检查内容 |
| --- | --- | --- |
| 本地 Argon | 2.4.3 / release 20250722 | 工作区 argon-base 的 Makefile、布局、基础、响应式、深色样式 |
| [上游 Argon](https://github.com/jerrykuku/luci-theme-argon/tree/0546f975a66796a89ff988524290c4a2e2d01855) | 2.4.7 / release 20260824；0546f975a66796a89ff988524290c4a2e2d01855 | less/cascade.less、layout.less、responsive.less、dark.less、ucode 登录模板 |
| [LuCI](https://github.com/openwrt/luci/tree/f4f91aee257bab4eb9c6b7de6160cea294217956) | f4f91aee257bab4eb9c6b7de6160cea294217956 | luci-base 的 ui.js、form.js、tools/widgets.js |

以上提交均固定链接，避免上游更新后行号失效。审计源文件与版本元数据保存在工作区 design-reference/argon-component-audit/。没有覆盖或执行这些源码，也没有改动 Argon 安装包。

## 职责划分

- **Argon 主题**：导航外壳、登录页、LuCI 控件的视觉样式、浅深色与响应式布局。
- **LuCI form / ui**：渲染字段与区块、表单验证、依赖关系、动态列表、弹窗、UCI 配置保存与应用。
- **C2000 UI**：在上述结构上制定自己的颜色、字号、间距与状态规范；增加 5G、温度、RAM / RootFS / SWAP 等业务展示。
- **插件页面**：软件包、文件管理器、终端、图表等可能自带 DOM 和逻辑。组件库提供基础模式，接入时仍需检查每个插件。

组件实现采用独立的 ui-* 类名。下表原选择器是兼容适配的依据，**不是已经覆盖到真实 LuCI DOM 的声明**。不把展示页的示例 JavaScript 注入 LuCI 表单。

## 组件目录

每一项包含可操作或静态状态示例、状态规范、原控件映射和可复制 HTML。状态列表表示设计需要覆盖的状态，不表示每项都有完整的真实后端流程。

### 导航与结构

| 组件 / 示例 | LuCI 控件或模块 | 原 DOM / 样式选择器 | 源码 |
| --- | --- | --- | --- |
| 表单区块 | form.Map / NamedSection / TypedSection / SectionValue | .cbi-map · .cbi-section · .cbi-value | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L406) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L363) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4131) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L6012) |
| 分级导航 | ui.menu | .main-left · .nav · .slide | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/layout.less#L23) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L3698) |
| 页面与区块标签页 | ui.tabs / AbstractSection.tab() | .tabs · .cbi-tabmenu · .cbi-tab-disabled | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L890) / [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L950) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L4623) |

### 操作与反馈

| 组件 / 示例 | LuCI 控件或模块 | 原 DOM / 样式选择器 | 源码 |
| --- | --- | --- | --- |
| 按钮与操作组 | form.Button / ui.ComboButton | .cbi-button-* · .cbi-page-actions | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L707) / [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L857) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L5471) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L2190) |
| 通知与告警 | ui.addNotification() | .alert-message · .notice · .warning · .danger | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L240) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L4359) |
| 加载与等待 | ui.createHandlerFn() / modal spinning | .spinning · .cbi-button[disabled] | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1835) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L4215) |
| 空数据与不可用 | ui.Table placeholder / form.DummyValue | .tr.placeholder · .td | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L129) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L3808) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L5368) |
| 弹窗与确认 | ui.showModal() / ui.hideModal() | .modal · #modal_overlay | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1721) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L4215) |
| 辅助提示 | ui.showTooltip() | .cbi-tooltip · .cbi-tooltip-container | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2309) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L4263) |

### 表单输入

| 组件 / 示例 | LuCI 控件或模块 | 原 DOM / 样式选择器 | 源码 |
| --- | --- | --- | --- |
| 文本与字段验证 | form.Value / ui.Textfield | .cbi-input-text · .cbi-input-invalid · .cbi-value-description | [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4311) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L313) / [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1180) |
| 密码与可见性 | form.Value.password / ui.Textfield | .cbi-input-password | [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4311) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L313) |
| 开关、复选与单选 | form.Flag / ui.Checkbox / form.ListValue.widget=radio | .cbi-checkbox · .cbi-input-radio | [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L573) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4999) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4619) |
| 单选与可输入选择 | form.ListValue / RichListValue / ui.Select / Combobox | .cbi-input-select · .cbi-dropdown | [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L716) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L2118) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4720) |
| 多选下拉 | form.MultiValue / ui.Dropdown(multiple) | .cbi-dropdown[multiple] · [selected] | [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L932) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L5165) / [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1579) |
| 动态列表 | form.DynamicList / ui.DynamicList | .cbi-dynlist · .item · .add-item | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1282) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4545) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L2319) |
| 多行文本与代码输入 | form.TextValue / ui.Textarea | .cbi-input-textarea | [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L450) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L5264) / [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1987) |
| 滑块与数值 | form.RangeSliderValue / ui.RangeSlider | input[type=range] | [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L2807) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L4859) |
| 文件选择与上传状态 | form.FileUpload / ui.FileUpload | .cbi-input-file · .cbi-progressbar | [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L3031) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L5653) |
| 文件与目录选择器 | form.DirectoryPicker / ui.FileUpload browser | .cbi-input-file · .cbi-filebrowser | [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L5841) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L3031) |

### 数据展示

| 组件 / 示例 | LuCI 控件或模块 | 原 DOM / 样式选择器 | 源码 |
| --- | --- | --- | --- |
| 数据表格与排序 | ui.Table / form.TableSection | .table · .tr · .th · .td | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L487) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L3808) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L2543) |
| 可编辑表格 | form.GridSection / TypedSection.addremove | .cbi-tblsection · .cbi-section-actions | [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L3918) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L2251) / [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1250) |
| 分页与工具栏 | ui.Table / page-specific pager | .controls · #pager | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2431) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L3808) |
| 资源与进度条 | Argon progressbar / page-specific resource rendering | .cbi-progressbar | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L1675) |
| 监控读数与趋势 | C2000 扩展 / LuCI status graphs | #bwsvg · #iwsvg / .stat-tile | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2169) |

### 配置流程

| 组件 / 示例 | LuCI 控件或模块 | 原 DOM / 样式选择器 | 源码 |
| --- | --- | --- | --- |
| 待应用变更 | ui.changes / form.Map.save() | .uci-change-list · .uci-change-legend | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2028) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L5131) |
| 保存、应用与回滚 | ui.changes.apply / confirm / revert | .cbi-page-actions · .uci-dialog | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L857) / [LuCI ui.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/ui.js#L5131) |

### 网络与系统

| 组件 / 示例 | LuCI 控件或模块 | 原 DOM / 样式选择器 | 源码 |
| --- | --- | --- | --- |
| 接口状态卡片 | widgets.NetworkSelect / DeviceSelect | .ifacebox · .ifacebadge · .network-status-table | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2177) / [LuCI widgets.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/tools/widgets.js#L463) / [LuCI widgets.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/tools/widgets.js#L575) |
| 防火墙区域与转发 | widgets.ZoneSelect / ZoneForwards / IPSelect | .zonebadge · .zone-forwards | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2214) / [LuCI widgets.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/tools/widgets.js#L43) / [LuCI widgets.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/tools/widgets.js#L244) / [LuCI widgets.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/tools/widgets.js#L359) |
| 日志与诊断输出 | view-specific diagnostics / form.TextValue | #syslog · .commandbox · .commands | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2003) / [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/less/cascade.less#L2492) / [LuCI form.js](https://github.com/openwrt/luci/blob/f4f91aee257bab4eb9c6b7de6160cea294217956/modules/luci-base/htdocs/luci-static/resources/form.js#L5264) |
| 登录与认证反馈 | Argon sysauth template | .login-page · .form-login · .errorbox | [Argon](https://github.com/jerrykuku/luci-theme-argon/blob/0546f975a66796a89ff988524290c4a2e2d01855/ucode/template/themes/argon/sysauth.ut#L95) |

## 组件状态与本轮实现

| 范围 | 已实现的示例 | 接入主题时需要保留的行为 |
| --- | --- | --- |
| 表单 | 文本校验、密码显隐、开关、多选、动态列表、滑块、依赖显示 | LuCI datatype / validate / depends、只读权限与实际配置写入 |
| 表格 | 过滤、排序、行编辑、添加、移除、上移、分页 | TableSection / GridSection 的渲染、分页数据、后端校验 |
| 反馈 | 告警关闭、空状态、加载完成、弹窗、键盘标签页、提示 | 后端错误语义、真实加载生命周期与重试 |
| 配置流程 | 暂存、模拟应用、确认、10 秒超时回滚、主动回滚 | ui.changes / UCI 后端的实际差异、超时、确认与回滚 |
| 文件 | 本地文件名 / 大小展示、固定目录选择 | ui.FileUpload 的权限、路径校验、上传进度、校验和；没有上传文件 |
| 登录 / 诊断 | 本地认证反馈、固定文本输出 | LuCI 会话与权限、RPC / fs.exec 返回；没有执行命令 |
| 网络 / 监控 | 接口 / 区域样式、容量条、示例趋势与读数 | network / RPC 数据、传感器单位、温控阈值与缺失状态 |

## 没有单独列成组件的 API

- form.AbstractSection / AbstractValue 是基类；form.JSONMap 是数据后端变体，复用区块和字段规范。
- form.HiddenValue / ui.Hiddenfield 无可见 UI；仍由 LuCI 负责值与权限。
- form.DummyValue 复用只读数据行；form.SectionValue 复用嵌套区块。
- UserSelect / GroupSelect、IPSelect、NetworkSelect、DeviceSelect、ZoneSelect 属于选择控件的业务变体，实际选项与权限不由主题生成。
- ComboButton 归入操作组；RichListValue 归入选择器。复杂图标选项与多选由 LuCI 原生 Dropdown 实现，展示页没有重新实现它的全部内部行为。
- 保存并应用是“保存 + 应用”的组合入口；本页拆开演示阶段，以显示待应用状态。实际页面应保留 LuCI 提供的组合入口。
- 标签页的 .cbi-tab-disabled 在 LuCI 中表示未选中页，不等于 HTML disabled。实际禁止选择必须另行表达。
- 工具提示与图表、诊断、分页含页面专用样式；不能把一个 CSS 类当作完整数据组件。

## 适配验收建议

1. 在目标固件中核对 LuCI / Argon 版本，确认使用 JavaScript / ucode 或旧模板路径。
2. 选系统设置、接口、防火墙、软件包、登录页作为代表页，保留原 DOM 结构、名称、ID、事件及校验。
3. 把语义 token 映射到对应选择器，逐项检查默认、聚焦、错误、禁用、只读、加载、空数据。
4. 用真实动态选项、长 IPv6 地址、长固件版本、长菜单和未知数据检查布局。
5. 在手机、平板、桌面和 200% 缩放下检查菜单、表格内滚动、弹窗焦点和底部操作。
6. 在测试设备验证应用失败、网络断开、会话超时和回滚；静态示例通过不代表这些后端流程通过。

本轮交付是组件设计、原生示例和规范文档。LuCI CSS 适配层、view 注册、RPC 数据、打包安装和实机验证需在后续主题开发中完成。
