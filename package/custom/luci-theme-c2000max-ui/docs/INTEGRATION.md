# 首页数据接入契约

| 字段 | 来源 | 规则 |
| --- | --- | --- |
| 内存、SWAP、运行时间 | system.info | 字节转 MiB，缓存包含 cached + buffered；总量 0 的 SWAP 显示未启用 |
| RootFS | system.info.root | 原接口 KiB 转 MiB |
| 上行 | network.interface.dump | 默认路由与启用的接口；不等于互联网探测 |
| SSID | c2000max.ui.sensors → network.wireless.status | 服务端读取驱动状态，只返回 radio 启用状态与 SSID，去重；不返回密钥 |
| 已连接设备 | luci.getOnlineUsers | br-lan IPv4 邻居，明确显示口径 |
| CPU | c2000max.hardware_status | 必须有 cpu_sensor，milli°C 转 °C |
| CPU 占用率 | c2000max.ui.metrics.cpu | `/proc/stat` 整机累计计数差值；idle 含 iowait，guest 不重复计数；首个样本显示采样中 |
| 活动连接数 | c2000max.ui.metrics.connections | 固定读取 conntrack 当前数量与上限；圆环表示上限占比，中心显示实际条数，与已连接设备数区分 |
| Wi-Fi 温度 | c2000max.ui.sensors | 固定 ra0 / rai0 的 mwctl CurrentTemperature，最高值；20 秒刷新 |
| 模组型号、固件、温度 | qmodem.base_info + base 缓存 | 30 秒独立刷新，动态读数 120 秒有效期，QModem 自行持有 AT 锁 |
| RSRP、SINR、频段 | qmodem.cell_info + cell 缓存 | 15 秒主动刷新，缓存每 5 秒读取；120 秒有效期；NSA 只选 NR 字段，Huawei MCC 兼容 MMC |
| NR 载波数量 | 主频段 + Band (CA) | 已上报主频段时至少 1 CA |
| 5G-A | 当前主 / 辅载波及运营商 | 联通 / 电信 ≥2 路 n78；移动 / 广电 ≥2 路 n41 且包含 n79 |
| SIM | c2000max.sim_status | 30 秒读取，120 秒有效期；external1 / external2 / internal 映射实际槽位，不做切换 |
| 温度状态 | data.hardware + c2000max_ui | 界面默认 80 / 90°C，UCI 可覆盖；不改硬件温控 |

## 刷新与隔离

`home.js` 先显示页面占位，再按组异步更新；其他基础状态每 10 秒更新。每组有 busy 标记，挂起期间不排队。system.info、模组 base/cell、缓存、SIM、传感器及 CPU 采样均使用独立 HTTP 请求，不加入快速状态的 RPC 批处理；沿用 LuCI 的请求超时。首页自己的两类串口读取串行执行，避免相互争抢 AT 锁；失败后 5 秒重试。慢查询不阻塞其他卡片，返回前台立即补读。

运行时间、内存、RootFS 和 SWAP 分组保存有效样本。系统请求超时、错误码、空响应或部分字段无效时，保留该组最近 60 秒内的有效值，其他有效组继续更新；失败重试和其他 RPC 不会延长样本有效期。更新失败或延迟超过 30 秒时显示简短提示，超过 60 秒的组恢复缺失占位。运行时间回退时清除旧启动周期的资源样本。

RAM 分配条以固定的空闲底色铺满，活跃与缓存部分做宽度过渡；空闲没有独立填充动画。图例仍显示实际空闲量，与 MemAvailable 的可用量区分。

系统状态每 5 秒独立采样，首个 CPU 样本后补采一次以建立占用率。重复的其他 RPC 更新不会重复消耗 CPU 样本；计数回退、请求失败或缺失字段显示占位，不伪装为 0%。metrics 只读三个固定内核状态文件，不等待、不执行命令。

首页 HTML 模板的缓存键跟随 LuCI 的包更新时间。升级主题后重载 rpcd，并重启 uhttpd 以刷新常驻 LuCI 运行时的包更新时间，使浏览器自动获取新的首页控制器和模板。

`c2000max.ui.modem` 只读固定 `/tmp/cache_{base,cell,sim,network}_info_<section>` 及 `/tmp/cache_info_<section>` 文件，单个 JSON ≤256KiB，节名限制为 1–64 字符的字母、数字、下划线。只返回首页使用的字段，附缓存代次及年龄；不返回 IMEI/IMSI 等身份字段。base/cell 查询完成后立即重新读缓存，避免把锁竞争时返回的旧快照误记为新数据。近期完整 info 快照仅补齐同制式、同小区的缺失字段；新主频段已返回时不能用 info 恢复退出的聚合载波。

前端按字段保留最近有效样本，空响应、无效数值和短暂失败不清空有效值；同一缓存代次不会续期。动态字段超过 120 秒失效，型号/固件仅允许同一设备的历史值。网络制式或服务小区变化会清除旧无线参数；新的主频段快照替换完整载波列表，防止保留已退出的聚合载波。更新较慢或字段缺失时显示简短刷新提示。

未安装插件、接口失败、缓存失效分别按缺失字段处理，不能伪装为正常。型号和固件允许较旧快照，实时信号与温度有有效期。页面不显示调试缓存行。

ACL 只授予读方法和 UCI 读取，QModem 权限仅为 base_info/cell_info，不提供任意 AT、fs.exec、uci.set、拨号、SIM 切换或重启权限。配置页行为由原生 LuCI 和插件处理。

## 登录与壁纸

登录使用原生 LuCI POST，不保存凭据，错误与用户输入编码输出。Bing 请求限定官方域名和图片路径，下载失败保留原图。

壁纸署名在登录框下方独立占位；手机最多显示两行，完整署名保留在链接文字和 title 中。小屏、横屏和长文字使页面自然滚动，不覆盖登录表单。

## 真机验证

目标为 ImmortalWrt C2000MAX / MT5700M-CN / MT7990E。已实读 CPU、ra0 / rai0、QModem 温度与 SIM 状态。设备的 CPU 热保护节点为 117 / 125°C；UI 的 80 / 90°C 是保守的显示提醒线，不以热保护极限充当日常温度分级。

不同插件分支的字段格式、第三方 iframe 和内联图表仍需独立验证。版本检查结果见验证记录。
