# 组件到 LuCI 的映射

密度规范以 [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md) 为准。生产主题和展示库共用 `tokens.css` 与最终 `density.css`。

| 组件 | LuCI 实现 |
| --- | --- |
| 分组 / 字段 | `.cbi-section` / `.cbi-value`；16px 分组内边距，8px 行内边距 |
| 输入 / 选择 / 按钮 | 原生 input / select、`.cbi-dropdown`、`.cbi-button`；桌面 32px，触屏 40px |
| 勾选 / 单选 | 原生语义，16px 图形，保留标签与焦点 |
| 动态列表 / 下拉面板 | 使用相同控件高度；展开面板保留 LuCI 的定位和滚动计算 |
| 页签 | `.tabs` / `.cbi-tabmenu`，窄屏内部滚动 |
| 表格 | `.table`，表头不拆字，单元格 8px × 10px |
| 弹窗 | `.modal`，减少嵌套层留白，细滚动条裁切于圆角 |
| 登录 | `sysauth.ut` 原生 POST，Bing 壁纸与毛玻璃卡片 |
| 导航 | `ui.menu.load()` 权限过滤菜单，手机抽屉与底部导航 |

组件库的演示脚本不加载到设备配置页。保存、校验、应用、回滚和无线操作继续由 LuCI 与插件处理。主题只申请首页所需的读接口。

特殊插件的 iframe、图表内联尺寸和独立文档仍需逐项适配。已验证页面清单和测量结果见版本验证记录。
