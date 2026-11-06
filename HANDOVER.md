# PluginNest 交接文档

> 版本：1.1.38（2026-11-02）｜ 目标：抖音 40.9.0（iOS 27.0.1 / rootless 越狱，Dopamine 类）
> 包名：`com.dpo.pluginnest` ｜ 构建：Theos / Logos，arm64 + arm64e，ARC
> 配套文档：`README.md`（功能与实现要点）、`PACKAGING.md`（打包细节）。本文档面向**接手维护的人**，重点讲机制、坑和历史故障档案。

---

## 一、项目一句话

把第三方插件塞进抖音设置页的所有入口**收进一个统一的「插件收纳」二级页**：主设置页只留一行入口，收纳页按插件分组（名称 + dpkg 版本号），支持页内搜索、开关双向同步。

## 二、构建与安装

```bash
# rootless（当前设备用这个）
make package SCHEME=rootless
# rootful
make package SCHEME=rootful
```

- 产物在 `packages/com.dpo.pluginnest_<版本>_iphoneos-arm64.deb`（rootless）与 `_arm.deb`（rootful）。
- 本机 Theos 缺 lzma，Makefile 已自动退回 gzip（`THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip`），换机器不用管。
- 安装：`dpkg -i xxx.deb && killall -9 Aweme`（必须完全杀掉抖音，切后台不算）。
- `make clean` 会连 `packages/` 一起删，注意先备份 deb。

## 三、文件职责

| 文件 | 职责 |
| --- | --- |
| `Tweak.x` | **唯一 hook 点**：`AWESettingsViewModel/AWESettingBaseViewModel` 的 `sectionDataArray`、`numberOfRows/numberOfSections`、header 四件套、`viewWillAppear` 等；`%ctor` 装配一切 |
| `DPOCommon.h` | 抖音私有类声明（`AWESettingItemModel` / `AWESettingSectionModel` 等，只声明不引用类符号） |
| `DPORuntime.{h,m}` | `DPOSettingsViewModelKind` 三态分类、`DPODigTopViewController`、block 镜像解析（dladdr）、拼音、触感、`DPOBuildVersion` |
| `DPOModel.{h,m}` | `DPOFeature` / `DPOPlugin` / `DPOStore`（仓库）与搜索排序 |
| `DPOPackageResolver.{h,m}` | dylib 路径 → dpkg 包名 + 版本（读 `/var/jb/var/lib/dpkg/status` + `info/*.list`），结果缓存进偏好 |
| `DPOHarvester.{h,m}` | **核心**（约 1500 行）：扫描、判定归属、主页面"减法"、子页嵌套收录、入口 section、执行插件回调、崩溃隔离 |
| `DPOViews.{h,m}` | 功能行（`DPOFeatureCell`）、分组头、**`DPOCardView` 浮卡容器**（半透明面 + 投影 + 按下/禁用态）、插件卡片行（渐变图标 tile + 版本列 + 蓝 chevron）、Toast（深底胶囊） |
| `DPOTheme.{h,m}` | **悬浮面板设计令牌层**：背板模糊/纱罩、面板半透明底 + 粉紫染色、浮卡三档填充、蓝（链接）/红（危险）/绿（状态）三色纪律、主题模式与「减少动效」开关，持久化在 `com.dpo.pluginnest` 偏好 |
| `DPOOrganizerViewController.{h,m}` | 收纳页 = **悬浮毛玻璃面板**：透明导航壳 + `overFullScreen` 溶解模态（插件回调仍可往 `delegate.navigationController` push）；背板模糊透出宿主页；头部头像 + 状态胶囊、搜索胶囊、一行一浮卡、底部 外观/诊断/日志 三个蓝图标按钮 |
| `DPOPluginDetailViewController.{h,m}` | 插件详情页 |
| `DPOGestureHub` / `DPOSearchPanelViewController` / `DPOPanelTransition` | **已移除**（原窗口级三指长按手势 + 全局面板） |
| `DPODiagnostics.{h,m}` | 归属诊断列表（排查漏收，列出每行 item 的 block 镜像/类名/判定） |
| `DPOLogCenter.{h,m}` | 运行日志：逐行 append 落盘（`O_APPEND`）、双路径回读、信号崩溃捕获（sigaction + backtrace 写 crash 文件） |
| `DPOLogViewController.{h,m}` | 日志页：查看 / 导出（`UIDocumentPickerViewController initForExportingURLs:asCopy:`）/ 清空 |

## 四、核心机制（接手前必读）

### 1. 主页面"减法"与三态分类

别的插件对 `sectionDataArray` 做"加法"，我们做"减法"：判定某行是第三方插件的，就把它从返回数组里摘走，原位只插一行「插件收纳」入口（**独立 section，insert atIndex:0，绝不复用插件的 section**——1.1.22 的入口泄漏就是这么来的）。

抖音主设置页和插件子页用**同一个 VM 类**，靠 `DPOClassifySettingsViewModel`（`DPOSettingsViewModelKind`：Unknown/Main/SubPage）区分：登记过的实例 + delegate 类名 + section 特征综合判定。Unknown 一律原样返回，绝不动。

### 2. 扫描策略：启动扫一次，新插件才补扫（1.1.35）

- `DPOSessionHarvestDone`：本会话是否已完整扫描过。
- `DPOKnownIdentifiers`（NSUserDefaults，上限 600）：上次完整扫描见过的所有行 identifier。
- `dpo_processMain:sections:force:` 每轮先算当前 identifier 集合：`已扫过 && !force && 没有未知 identifier` → **快速过滤路径**（只用 `DPOCollectedIdentifiers` 隐藏名单过滤 + 插入口段，不重新收集、不 dladdr、不打 ITEM 日志）；否则完整扫描并 `dpo_rememberIdentifiers:`。
- 收纳页右上角刷新按钮 = `[DPOHarvester resetScanCache]`（清 known + 会话标记 + 缓存 + 强制下轮扫描）→ toast「已重新扫描」。新装插件不重启也能收录。
- **跨启动做不到"永不扫描"**：插件功能是宿主页面里的 item + block，页面销毁即失效，每次启动至少要重新绑定一次。

### 3. 归属判定：block 镜像，不是关键字

`cellTappedBlock/switchChangedBlock` 的 invoke 指针 `dladdr` 出所在 Mach-O 镜像：落在 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`、`/var/jb/usr/lib/TweakInject/`、`Aweme.app/Frameworks/*.dylib` → 第三方插件；落在宿主 framework / 系统库 → 不动。纯展示行无 block 时用"同插件已知 identifier 前缀"兜底。

### 4. 子页只读 + 激活登记

- `handleSubPageViewModel:` **只读不写**（不改插件页 section），`processedSections` 缓存 0.5s TTL。
- `DPOBeginActivation(pluginImage)` 在执行插件回调前登记"当前激活插件"（5 分钟有效），子页嵌套收录据此归属。
- **`mergeNestedFeatures:` 不得把嵌套 identifier 写进 `DPOCollectedIdentifiers`**——该集合只服务主设置页行隐藏，写进去会把插件自己页面的行藏光（1.1.37 的「DYKiller 页只剩免责声明」就是这么炸的）。

### 5. 行映射：保留空段占位（1.1.26，最惨烈的教训）

`DPORowMapForController` 必须为数据源**每一个 section 保留占位**（空段 rows 为空数组），段数恒等于数据源段数，不能为了省事丢掉空段、也不能加缓存——否则转场布局时段号变化触发 `-[UITableViewRowData numberOfRowsInSection:]` 断言 abort（DYKiller/抖⁺ 连开第二个必闪退）。配套四个 header hook（`heightForHeader/viewForHeader/titleForHeader/willDisplayHeader`）把空段 header 压到 0.001/nil/hidden，避免"行藏了标题还在"的空标题残留。

### 6. 执行插件回调（activateFeature:from:）

执行前从**收纳页下面那个设置页 VC** 取活 VM（`[settingsController valueForKey:@"viewModel"]`），触发 `[liveViewModel sectionDataArray]` 让插件重建入口（新 block 绑定活 VM），再按 key 从仓库重取 feature；delegate 设在 `liveViewModel ?: feature.viewModel`；**不 pop**（用户明确要求删掉"先退回设置页再打开"）。

**DYKiller 专用直调路径**：先 `DPOBeginActivation`，再 `dlsym(RTLD_DEFAULT, "DKSettingsOpenMain")`（失败 `dlopen(pluginImage)` 后重试），直接调它导出的 C 入口 push 页面，成功即 return，绕开其源码里 `weakSelf → controllerDelegate` 可能为 nil 的静默失败（官方 0.6.9.2 已 `nm -g` 验证导出；用户设备装的 0.7.7 来自 fork，符号目前也在）。日志标记 `用 DKSettingsOpenMain 打开 DYKiller`。

### 7. 崩溃隔离与恢复

`DPOGuardBeginActivation/EndActivation` + `DPOIsQuarantined/SetQuarantined`：某插件在激活过程中崩溃（信号被 DPOLogCenter 捕获）→ 写入隔离名单（key 含版本号，`DPOGuardBuild` 变更即清空）→ 下次点击弹"上次导致崩溃，是否仍要打开"，仍打开则先恢复现场。隔离弹窗延后一个 runloop present，避免和页面转场打架。

### 8. 日志

落盘 `/var/mobile/Library/Preferences/com.dpo.pluginnest.log`（写不进退回 tmp，`access(W_OK)` 探测），逐行 `O_APPEND` write 防崩溃丢行，启动双路径回读取较新者。信号处理器写 `tmp/com.dpo.pluginnest.crash`。1.1.38 降噪后：PAGE 日志 3 秒节流（同 owner 且嵌套数不变不打）、SUBPAGE 逐条已删、合并日志仅数量变化时打。导出必须用 `UIDocumentPickerViewController`（UIActivityViewController 会拉起分享扩展导致闪退）。

**坑：dylib 里的中文字符串是 UTF-16LE**，`strings` 看不到，校验产物要用 Python 按 `utf-16-le` 编码搜。

### 9. 聚合搜索（1.1.46）

1.1.38 删掉全局面板后，`DPOSearchFeatures()` / `allSearchableFeatures` / 深层索引全部变成**死代码**（模型层完整、零调用方）。1.1.46 把这一层重新接通：

- **入口（1.1.51 改）**：收纳页顶部胶囊就是**输入框本身**，输入即就地过滤（不跳页）。结果按插件分组复用 `DPOFeatureCell`，点一行走 `locateFeature:`。原独立搜索页已删除。
- **语料**：`allSearchableFeatures` = 活入口（`groups[].features`）+ 深层索引（`deepFeatures`）+ 静态索引（`staticFeatures`），按「插件镜像 + title」去重，**活入口优先**。
- **排序**：全部交给 `DPOSearchFeatures()`（六档打分，静态项 −30 降权）。搜索页只按插件分组，**不重排**，保证分数顺序不被破坏。
- **深层索引从哪来**：`handleSubPageViewModel:` 里把**本页自己的** item 转成 `DPOFeature(isDeep = YES)` → `mergeDeepFeatures:`。带 `locatorPage`（VM 类名）/`locatorIndex`（页内序号）/`locatorTrail`（[分组, 标题]）。上限 150 条/页，仓库整体 600 条，`DPODeepIndexDefaultsKey` 跨启动持久化。
- **别走错路**：自家条目**不能**塞 `mergeNestedFeatures:`——那条路径是「本页里别家插件的入口」，会写 `DPOCollectedIdentifiers` 隐藏名单（1.1.36/37 的 DYKiller 事故就是这么来的）。
- **点击（1.1.49）**：`locateFeature:from:`。活入口直接执行；深层项先打开插件页，再按 `locatorTrail` 一级级重放：每 0.45s 扫一次当前最上层表格，找到目标行 → `scrollToRow` + 高亮闪烁；没找到就点下一级入口继续下钻。二级、三级菜单都是同一条逻辑（路径 = 激活链 + 目标标题）。
- **激活链**：`DPOActivationTrail`（最多 3 层）在 `activateFeature:` 里 push、回到主设置页时 Reset。深层索引靠它生成「可重放」的路径，否则三级页根本走不到。
- **自检**：日志 `PAGE` 行现在多一个 `深索引=N` 字段；收纳页 ⓘ 诊断页可看归属。
- **持久化（1.1.47 修）**：`DPOFeatureStore -init` 原来**主动删掉** `DPODeepIndex.v1` / `DPOStaticIndex.v1` 两个 key、且从不调用 `_loadDeepIndex` / `_loadStaticIndex`（1.1.38 "搜索下线"时留下的）。现在改成 init 里把两份索引读回来。**没有这行修复，每次重启抖音都要重新逛一遍插件页。**

## 五、历史故障档案（按版本）

| 版本 | 问题 | 根因与修复 |
| --- | --- | --- |
| 1.1.10 | 叠层 X 不掉 | 早期 UI 层级问题（已被后续重构覆盖） |
| 1.1.19→20 | DYKiller/抖⁺ 一点就闪退（自己引入的回归） | 把 `controllerDelegate` 指向不可见 VC，插件拿它 present → 异步异常。回退 delegate=presenter。教训：**别替插件保管上下文** |
| 1.1.22 | 入口行泄漏进插件页（续火花 header 下出现「插件收纳」行） | 入口插进了插件静态缓存 section → 改独立 section |
| 1.1.24 | 崩溃后日志丢失 | 路径解析两轮不一致（写 tmp 读 Preferences）→ 逐行 append + 双路径回读 |
| 1.1.26 | UITableView 段号断言 abort（DYKiller/抖⁺ 连开第二个必崩） | 行映射丢空 section → 保留占位 + 删 0.3s 缓存。**改行映射前先读第四节第 5 条** |
| 1.1.27/28 | 插件页空标题残留（XUU²/续火花） | 行藏了 header 没藏 → 四个 header hook |
| 1.1.30 | DYKiller "只能开一次" | 其源码 `weakSelf → if(!rootVC) return`，VM 被抖音释放后静默失败。改为取活 VM 刷新 feature（`__block` 承载） |
| 1.1.31/34 | 搜索面板 UI | 容器改 `UIVisualEffectView(SystemUltraThinMaterialLight)` + 0.06 白 tint + 0.5pt 高光边；卡片白底 0.16、边框 0.25、圆角 18。之前像灰白块是 55% 白卡片 + 18% tint 叠出来的 |
| 1.1.34/35 | 扫描太臃肿 | 会话单次扫描 + `DPOKnownIdentifiers` 增量补扫（见第四节第 2 条）。DYStorage 其实每次全量扫，没照抄 |
| 1.1.36/37 | DYKiller 页只剩免责声明 | `DPOActivePluginImage` 停在上一个插件，DYKiller 自己的 10 行被当"别家入口"收走并写进隐藏名单 → BeginActivation 提前 + mergeNested 不再写 `DPOCollectedIdentifiers` |
| 1.1.38 | 日志刷屏（SUBPAGE 一次 10 行、一页刷三遍） | 删逐条、PAGE 节流 3s、合并日志仅变化时打。~33 行/页 → 1-2 行/页 |
| 1.1.46 | 搜索胶囊点了弹「下次一定」 | 1.1.38 移面板时把 UI 删了却没删模型，`DPOSearchFeatures`/`allSearchableFeatures` 成了零调用死代码。本次补 `DPOSearchViewController` + 深层索引接线（见第四节第 9 条） |
| 1.1.47 | 深层索引每次重启清零 | `DPOFeatureStore -init` 里还留着 1.1.38「搜索下线」的 `removeObjectForKey:`，且两个 `_load*Index` 从没被调用 → 落盘写了也白写。改成 init 时回读 |
| 1.1.48 | AwemeX 这类插件搜不到 | 它不用抖音的 `AWESettingSectionModel`，自己搭 VC + TableView，harvest 完全看不见。加「看见即收录」：hook `-[UITableView _willDisplayCell:forRowAtIndexPath:]`，按类镜像反推归属 |
| 1.1.49 | 搜到了要自己翻 | `locator*` 只存不用。补 `locateFeature:`：激活链重放 + 滚动 + 高亮，二级三级菜单都能自动走到 |
| — | alert 无限递归爆栈 | `DPODigTopViewController` 遇 alert→presenting→parent 环 → depth≤12 上限 |
| — | 导出日志闪退 | UIActivityViewController 拉分享扩展 → 改 DocumentPicker export |

## 六、已知遗留问题

1. **抖⁺（闭源）走 block 路径**，偶发"点了没反应"（block 内 weak 上下文死亡），有 toast「XX 没有响应」提示，重启抖音可恢复。闭源无法像 DYKiller 那样直调。
2. **dpkg 版本号偶尔读不到**（沙盒限制）→ 显示「版本未知」，可用 overrides plist 手动补（见 README 第五节）。
3. 用户设备 DYKiller 装的是 0.7.7（fork），官方仓库最新 0.6.9.2；若该 fork 未来删掉 `DKSettingsOpenMain` 导出符号，dlsym 失败会回退 block 路径（日志可见）。
4. 只处理走 `sectionDataArray` 的入口；插件直接塞自定义 View 的无法摘取。
5. `DPOStreakHelper` 直推逻辑（`dpo_openStreakHelperIfNeeded`，0.6s 后触发）只限设置栈上下文，且排除 AwemeX/DouyinHelper。
6. **深层项定位是「尽力而为」**：`locateFeature:` 最多重试 20 次（约 9 秒），且顶部只要还是 PluginNest 自己的页面就不点任何东西，失败会 toast「没找到「X」」。路径依赖 `DPOActivationTrail` 记录的点击链——**如果某个层级是异步加载出来的（先转圈再出列表），可能来不及下钻**；日志 `LOCATE` 能看到停在哪一级。
7. **静态索引仍是空的**：`replaceStaticFeatures:` 依然没有调用方。要让「从没打开过的插件页」也能搜到，还得加 dylib 字符串扫描（P2）——但实测 AwemeX 的中文是加密的，这条路对它无效。

## 七、日志标签速查

```
BOOT    版本号、pid                 MAINVM  主设置页 VM 登记
HOOK    挂载成败与原因             HARVEST 扫描轮次/数量
ITEM    单项归属判定（完整扫才有）  RESCAN  补扫/重扫
ACT     点击了什么、走哪条路径      TOGGLE  开关
PKG     dylib→包名/版本            CRASH   崩溃栈
PAGE    子页摘要（3s 节流，1.1.38） DKSettingsOpenMain  DYKiller 直调成功
CAPTURE 看见即收录（1.1.48）    LOCATE  定位：下钻 / 命中 / 失败（1.1.50）
```

## 八、排障决策树

1. **入口没收走** → 收纳页 ⓘ 诊断页看该项的 block 镜像：没有 → 非标准注入；有但路径怪 → 补 `DPOPluginImageForItem` 的镜像规则。
2. **插件打不开** → 日志搜 `ACT`：走了 block 且无异常但页面不动 → 插件内部 weak 上下文死（DYKiller 型，找导出函数 dlsym 直调）；有崩溃栈 → 看隔离名单。
3. **闪退** → `tmp/com.dpo.pluginnest.crash` 或 ips 文件；若是 UITableView 断言 → 先查行映射有没有动过空段。
4. ** DYKiller 页面内容消失** → 查日志 `PAGE owner=` 是否正确，确认 mergeNested 没把嵌套 id 写进隐藏名单。

## 九、环境备忘

- 开发机：Apple Silicon Mac（macOS 13.7），Theos 在默认位置，`make package SCHEME=rootless` 一发入魂。
- 参考项目：`DYYYStreakHelper-src`（用户桌面，续火花源码）、DYKiller（github.com/HierarchThurs/DYKiller）、DYStorage（增量扫描参考，其实现有坑）。
- 抖音头文件基线：`DY40.9.0`（用户桌面）。

---

## 十、本轮审查修复记录（1.1.38 源码基线）

### 功能移除

**三指长按全局面板已整体移除**：`DPOGestureHub.{h,m}`、`DPOSearchPanelViewController.{h,m}`、
`DPOPanelTransition.{h,m}`、`DPOViews` 里的 `DPOSearchField` 全部删除，`Tweak.x` 里
`%ctor` 的 `[[DPOGestureHub shared] start]` 与 `<DPOGestureHub.h>` 引用一并去掉。
收纳页自己的搜索框（`DPOOrganizerViewController` 顶部 `UITextField`）与 `DPOEmptyView`
不受影响，仍可正常过滤。`DPOSearchFeatures` / `DPOFeatureStore.allSearchableFeatures`
目前没有调用方（仅原面板用过），保留待用。

顺带把 `Tweak.xm` 改名为 `Tweak.x`：该文件没有 C++ / `MSHookIvar`，按 Logos 约定用 `.x`。

### 修复清单

| 文件 | 问题 | 处理 |
| --- | --- | --- |
| `DPOModel.m` | `updateWithGroups:` 内容签名相同就整体 return，导致仓库继续沿用**上一轮**的 `DPOFeature`（其 `item`/block 绑定的是已经释放的旧 VM）→ 设置页重建后「插件只能打开一次」 | 分组对象始终换成最新实例，只有「是否发通知」看签名 |
| `DPOHarvester.m` | `handleMainViewModel:` 重入时返回 `DPOCachedResult`，可能属于另一个 VM，段数/行数对不上 → UITableView 断言 | 重入直接返回调用方传入的 `sections` |
| `DPOHarvester.m` | `collectAndRemoveThirdPartyItemsInSections:` 收走入口却不写 `DPOCollectedIdentifiers`，插件重建 section 后入口会重新冒出来 | 补收时登记 identifier |
| `DPOHarvester.m` | `setFeature:enabled:` 先改 `feature.isOn` 再判断 item 是否存在，插件未加载时开关会「假装拨过去了」 | 先校验 item，再改状态 |
| `DPOHarvester.m` | `byImage[feature.pluginImage]` / `byImage[...] =` 空镜像当字典 key 会抛异常 | 跳过空镜像 |
| `DPOHarvester.m` | 宿主设置页重建出的新 VM 被当成插件子页 → 官方设置项被写进深层索引（会落盘） | `DPOPageOwnedByHostSettings()` 挡住子页收录 / 索引 |
| `DPORuntime.m` | `DPOPluginImageForBlock` 用私有类名 `NSBlock` 判断，取不到时整条归属判定静默失效（插件全漏收） | 改看 isa 类名是否含 `Block` |
| `DPORuntime.m` | 未登记 VM + delegate 未设时一律当插件子页 | 改为 Unknown（不动） |
| `DPOPackageResolver.m` | 后台线程原地改 `DPOPluginInfo` 的 nonatomic 属性，主线程同时读 → 可能读到半更新指针 | 构造新对象，锁内整体替换缓存 |
| `DPOOrganizerViewController.m` | 没人监听 `DPOPluginInfoDidUpdateNotification`，异步解析出的包名/版本永远不显示 | 订阅该通知 + 商店更新通知，补到卡片上再刷新 |
| `DPOOrganizerViewController.m` | `[nil rangeOfString:]` 返回 `{0,0}`，空名字会被当成命中 | 先判 `length` |
| `Tweak.x` | `willDisplayHeaderView:` 只把 header 置 `hidden = YES`，从复位位 → 段重新有行后标题永久不显示 | 双向设置 `hidden` |
| `Tweak.x` | `DPOInstallContainerHooks` 类没注册时也置 `installed = YES`，之后再也不会补挂 | 只有真挂上才算安装，并在设置页出现时重试 |
| `Tweak.x` | `DPOScheduleHookUpgrade`（无人调用）、`DPOScheduleSettingsRescan` / `DPOPerformSettingsRescan`（无人调用）属死代码 | 删除前者的声明与实现；后两者保留但注明未接入 |

### 仍未处理（已知遗留）

1. `DPOPerformSettingsRescan` / `DPOScheduleSettingsRescan`、`countThirdPartyItemsInSections:`、
   `purgeThirdPartyItemsInSections:` 目前没有调用方（`-Wno-unused-function` 让它们静默通过）。
   如果要恢复「页面出现后物理清除残留」这条路，在 `DPOHookedMainVCWillAppear` 里调
   `DPOScheduleSettingsRescan(self)` 即可。
2. `DPOFeatureCell`、`DPOPluginHeaderView`、`DPOPluginDetailViewController` 当前没有引用（收纳页已改成
   单卡片 + 直接跳插件页）。删除前先确认没有 fork 在用。
3. `DPOLogCenter` 信号处理器里用了 `strsignal`（非 async-signal-safe），崩溃极小概率再次崩在
   handler 内；`DPOLogViewController` / `DPODiagnostics` 的导出与复制不受影响。
4. 行映射 `DPORowMapForController` 每次调用都会重新取 `sectionDataArray` 并全量重建 map（表格布局
   时会以「行数 × 每次」的规模重复计算）。**这不是普通性能问题，不要随手加缓存**：1.1.26 的
   断言崩溃就是缓存导致的段号错位，详见第四节第 5 条。
5. 发布前记得同步 `control` / `DPOBuildVersion`：版本号变化会顺带清空崩溃隔离名单。
