# DYStorage 1.3.1 更新说明

本版不改变收纳逻辑的使用方式，重点是构建/发布链路的正确性与设置页的健壮性。

## 新增功能

- 收纳提示：设置主页出现未收录的单项插件入口时，收纳页会新增「发现的插件入口」分组，点一下即加入收纳名单（写入 `DYStorageConfirmedPluginTitles`），不点则完全不动原始 section。
- 本机学习索引：从收纳页打开插件后，DYStorage 记录该插件页的功能名称与分组（上限 400 条，窗口 8 秒，重新渲染顺延 4 秒），与静态目录合并供聚合搜索使用，解决「收纳了但搜不到」的问题。数据只存在本机 `NSUserDefaults` 的 `DYStorageRuntimeCatalogV1`。
- 搜索栏深浅色自适应：按宿主背景亮度判定深浅，跟随抖音自身的深浅色开关与系统外观，不再出现深底深字。
- README 增补「插件发现、索引与外观」一节，说明三个机制的判定条件、上限与清理方式。

## 版本与打包

- 版本号改为单一来源：`control` 的 `Version` 在编译时注入 `kDYSTORAGE_VERSION_STRING`，包内声明与设置页底部显示不再各写一份。
- 修正打包架构：rootful 产出 `iphoneos-arm`，rootless 为 `iphoneos-arm64`，roothide 为 `iphoneos-arm64e`；`control` 只声明基础架构，其余由 Theos 方案覆盖。
- `control` 补充 `Depends: firmware (>= 14.0), mobilesubstrate` 与 `Homepage`，避免低版本系统直接安装。
- CI 在打包后逐包核对架构、版本、依赖与 dylib 切片（arm64 + arm64e），不一致就失败，不再依赖肉眼检查。

## 稳定性

- 设置页组装 `sectionDataArray` 时增加异常兜底：第三方插件返回异常模型时回退到原始数据，不再把异常抛给抖音设置页。
- 主页判定增加兜底：当抖音调整「账号 / 账户」分组标题时，只要主页存在已知插件的单项根入口 section，「插件收纳」入口就不会静默消失。
- 聚合搜索时按页脚实际高度回退 `contentInset.bottom`，清空搜索后恢复，搜索结果底部不再留出 112pt 空白色块。
- 修复开发者扫描器遍历 `UISegmentedControl` 时的有符号比较警告，`-Wall -Wextra` 下可干净编译。

## 目录与发布

- 新增 `scripts/validate_catalog.py`：构建前校验聚合搜索目录能否解析、插件名是否在 `DYStorageKnownPluginTitles` 中、标题是否为空，并报告重复标题。
- 当前目录 6 个插件共 712 条功能；重复标题已记录为警告：DYKiller「清透玻璃」×4，DYYY「隐藏红包悬浮」×2、「隐藏评论搜索」×2。
- 推送 `v*` 标签会自动构建并创建 GitHub Release，上传三个 `.deb` 与一个独立 `.dylib`；手动触发仍可用，artifact 保留 30 天。
- 第三方 `theos-action` 固定到提交 `c5ddc77`，`actions/checkout` 升到 v7、`actions/cache` 升到 v6。

## 清理

- 删除不再参与编译的历史文件：`Tweak.x`、`DYPluginsViewController`、`DYPluginsMgr`、`DYPluginModel`、`DYPluginMgr.plist`。

## 升级建议

- 覆盖安装即可。rootful 设备请确认安装 `-rootful.deb`（`Architecture: iphoneos-arm`）。
- 抖音与第三方插件均使用私有界面，具体页面跳转仍建议在实机复核。
