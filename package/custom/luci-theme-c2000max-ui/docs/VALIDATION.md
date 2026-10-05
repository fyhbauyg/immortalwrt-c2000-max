# 验证记录

版本：`1.0.22-r1`；日期：2026-10-05。

## 独立仓库验证

- 源码、模板、运行时资源、RPC/ACL、构建工具和测试在本仓库中独立维护。
- 测试依赖由 `package.json` 声明，`pnpm-lock.yaml` 固定 Playwright 1.63.0；不引用其他项目的 `node_modules`。
- 构建树与验证运行时通过 `OPENWRT_ROOT`、`UCODE_BIN`、`UCODE_LIB_DIR` 指定，不包含本机绝对路径。
- 测试使用合成数据。设备诊断脚本、真实设备备份、构建产物和测试截图未提交到仓库；README 的精选界面预览图保存在 `docs/screenshots/`，同样使用示例数据。

## 已通过的检查

- 数据转换：CPU 差分采样、活动连接、内存单位、空值、温度、运营商、SA/NSA、LTE 与聚合。
- 系统刷新：请求超时、错误码、空响应和部分字段无效不会清空近期读数；分组过期、恢复及设备重启均已验证。
- 模组刷新：部分失败、样本过期、聚合变化、延迟响应、网络制式变化和设备隔离。
- 节日外观：北京时间边界、手动选择、刷新持久化、后台恢复和跨标签页更新。
- ucode：所有模板及 RPC 编译，首页与登录/错误登录模板实际渲染；壁纸服务脚本语法检查。
- 验证运行时：从配置好的 OpenWrt 构建树生成原生 ucode 与 fs 模块。
- 浏览器：首页、登录、代表性 LuCI 表单的浅/深外观及六种宽度，共 36 组布局；无横向溢出和脚本错误。
- 页脚：管理页与登录页署名链接指向本仓库，在新标签页打开并包含 `noopener noreferrer`。
- 系统状态：文字左对齐、圆环留白对称、分隔样式一致；四种桌面/平板宽度与四种外观，另检查四种手机宽度。
- 资源布局：手机图标与标题留白、系统/频段标签字体一致、双列布局的模组与温度卡片等高，温度采用两行横向读数与细分隔线；浅/深外观共 28 组尺寸检查。
- 登录壁纸：长署名不覆盖表单；离线回退、重新联网、失败保留原图和署名转义。
- 首页控制器：可选接口缓慢不阻塞其他卡片，不重复排队，模板缓存键随包更新。
- 内存与存储进度动画及减少动态效果偏好；RAM 空闲底色保持全宽，不参与填充动画。

## 重跑入口

```sh
pnpm install --frozen-lockfile
pnpm test
OPENWRT_ROOT=/path/to/openwrt bash tools/build-validator.sh
UCODE_BIN="$PWD/build/ucode/ucode" UCODE_LIB_DIR="$PWD/build/ucode" \
  OPENWRT_ROOT=/path/to/openwrt bash tools/validate-templates.sh
pnpm exec playwright install chromium
pnpm run test:browser
OPENWRT_ROOT=/path/to/openwrt bash tools/build-local.sh
```

浏览器检查也可设置 `PLAYWRIGHT_CHANNEL=msedge` 使用本机 Edge。产物和截图保存在 `build/`，不进入 Git。

## 验证范围

实机环境为 ImmortalWrt 25.12-SNAPSHOT / C2000MAX / MT5700M-CN，已验证登录、首页数据与原生 LuCI 页面显示。其他固件分支、模组厂商、第三方 iframe 和独立图表需在对应设备上验证。
