# V37.01 固定驱动源码输入

当前 Makefile 从 `file://$(TOPDIR)/local-sources` 读取以下三个输入，不依赖开发者的绝对家目录。本次发布经提供者确认具备公开分发权，随源码保留这三个原始构建输入及其许可声明。在仓库根验证：

```sh
bash scripts/c2000max/check-local-sources.sh
```

| 文件 | SHA256 |
| --- | --- |
| `c2000max-deco-wifi-765c6bef-source.tar.xz` | `847e6794beb86713fc9ab08f620e78dca3b537bb1677960937f6ec66a430ccd3` |
| `mt_wifi_osal-a53418.tar.xz` | `dfa4b178f198504a707dec957242f8ede1a732823e940faa6304c723ac3224ad` |
| `warp_20250919-9c1cfa.tar.xz` | `f644bb165b0c1d05167d09dea91a678b7304238dae82dfe541bfd3e2920be28a` |

不要用文件名相近的其他 SDK 包替代，不要关闭 Makefile 中的哈希检查。`c2000max-deco-wifi-765c6bef-code.tar.xz` 是中间归档，不是当前构建输入。

## 来源与边界

- 主驱动归档是本项目从用户提供的 `deco-be25-5g-logan-source-20260908.tar.xz` 中整理的 `mt7993_wifi_driver` / `mt7993_wlan_hwifi` 配对子树，并保留本目标需要的既有 EEPROM 模板；不是路由器 Flash/TF 运行数据的导出。
- 上游候选输入 SHA256 为 `765c6bef02348e1613130ba151518a15965ba6a77eccad5cdbe8329e0e578dfc`。资料将其来源标注为 Deco BE25-5G 的公开 GPL 包；本项目对候选成员和哈希做了一致性检查，未重新下载整个原始厂商分发包验证来源。因此不能把 `765c6bef` 冒充厂商 Git 提交或数字签名。
- WARP 和 OSAL 是用户提供的对应版本归档；保留其原始字节及许可声明。部分源码声明 GPL/BSD，主包也含原厂专有许可文字及第三方 NOTICE，不能将整个目录统一重新授权。
- 请仅使用、分发自己有权使用或分发的文件。源码补丁与发布说明不授予额外的第三方许可；没有获取授权的原始归档不能由本项目的包名或版本号代替。
- WM/ROM 运行固件由 `package/mtk/drivers/mt_hwifi/firmware-experimental.mk` 单独固定来源与哈希，不在这三个归档中补造；不含可用 TESTMODE 固件。
- 这些输入、补丁及本地镜像已通过编译和离线校验，但运行时完整 ABI、MLO 共存、吞吐及长稳限制仍以 [正式版更新日志](../docs/releases/V37.01-20260909.md) 为准。

正常检出应包含这三个归档。如果使用不完整源码拷贝或稀疏检出，CI 会明确提示缺失文件，不会静默回退旧驱动或跳过哈希。不能仅凭源码分支存在就宣称云端已完成构建。
