# DYstorage · 抖音插件收纳

把抖音设置页里**所有第三方插件入口**统一收进一个二级页：显示插件名 + 版本号、按插件分组，
开关与插件自身设置页双向同步；搜索功能当前封存。

> 目标进程：`com.ss.iphone.ugc.Aweme`（抖音 Aweme）
> 参考基线：DY40.9.0 头文件 + DYYY 开源实现
> 构建：Theos / Logos，arm64 + arm64e，ARC

---

## 一、它解决什么问题

装了 DYYY、抖增、净化之类的插件后，抖音设置页会被塞进一堆入口：
有的挂在第一屏、有的自成一段、有的藏在二级页，名字还各不相同。
DYstorage 做三件事：

1. **收**：把第三方插件注册到设置页的每一行都摘出来，原位置只留一行「插件」；
2. **归**：按「插件」分组，显示插件名 + 版本号（来自 dpkg），一个功能只属于一个插件；
3. **找**：搜索功能当前封存：点顶部搜索胶囊只提示「下次一定」，请在插件列表里按插件翻阅。

---

## 二、功能清单

| 能力 | 说明 |
| --- | --- |
| 通用收纳 | 不依赖关键字白名单，按「设置项由哪个 dylib 创建」判定归属，新插件无需适配 |
| 名称 + 版本 | 从 dpkg `status` + `info/*.list` 反查包名与版本；读不到时显示「版本未知」 |
| 一一对应 | 每个功能归属唯一插件，重复注入的副本会被去重 |
| 搜索 | 当前封存：点搜索胶囊提示「下次一定」，不提供查询与结果页 |
| 深层索引 | 打开过某个插件的子设置页后，**该页自己的**功能也会进入索引（150 条/页、总计最多 2000 条，跨启动持久化） |
| 开关同步 | 收纳页卡片打开插件页、功能行拨开关 = 调插件自己的 `switchChangedBlock`，并回写 `isSwitchOn`、刷新原 cell |
| 状态回读 | 从插件自己的设置页返回时，重新抓取最新实例，开关状态不会错位 |
| 动画 | 卡片按压微缩放、行按压微缩放、开关触感反馈 |

---

## 三、交互路径

```
抖音「我」→ 右上角设置
        └─ 第一段顶部：插件  3 个插件
              └─ 收纳页（按插件分组的卡片列表）
                    ├─ 顶部搜索胶囊 → 提示「下次一定」（搜索当前封存）
                    ├─ 插件卡片：图标 + 名称 + v版本号 + 入口标题
                    └─ 点卡片：执行该插件自己的入口回调，打开它的设置页

运行日志：收纳页标题连点五次进入（导出、清空）；诊断：列表为空时点「查看诊断」
```

---

## 四、安装

```bash
# rootless（Dopamine / palera1n rootless / ElleKit）
make package SCHEME=rootless

# rootful
make package SCHEME=rootful

# roothide
make package SCHEME=roothide
```

产物在 `packages/`，安装后**完全退出抖音**再打开（不是切后台，是从多任务里划掉）。

当前发布包：`DYstorage_1.1.72_iphoneos-arm64.deb`。包标识仍为 `com.dpo.pluginnest`，
`control` 已声明 `Conflicts/Replaces: com.xlzs001.dystorage`，安装时会替换旧 DYStorage。

发布页：<https://github.com/xlzs001/DYstorage/releases>

卸载：

```bash
dpkg -r com.dpo.pluginnest
```

---

## 五、实现要点

### 1. 怎么判断「这一行是插件塞的」

不猜标题关键字，而是看这个设置项的 `cellTappedBlock` / `switchChangedBlock`
**函数指针落在哪个 Mach-O 镜像里**：

```objc
// Block_layout.invoke → dladdr() → dli_fname
NSString *image = DPOPluginImageForItem(item);
```

- 落在 `/var/jb/Library/MobileSubstrate/DynamicLibraries/…`、`/var/jb/usr/lib/TweakInject/…`、
  `/Library/MobileSubstrate/…` → 第三方插件；
- 落在 `Aweme.app/Frameworks/*.dylib`（独立注入的插件，常见于插件加载器）→ 第三方插件；
- 落在 `Aweme.app` 内的 `.framework/`、`AwemeCore`、`/System/Library`、注入框架本身 → 不动。

这样官方项永远不会被误收，新插件也不需要往白名单里加名字。

少数纯展示行没有 block，则用「同插件已知 identifier 前缀」兜底归属。

### 2. 为什么每次都要重新取 item

抖音设置页每次刷新都会重新生成 `AWESettingItemModel`，插件的 `cellTappedBlock`
里往往弱引用了当时的控制器。收纳页只保存**当次最新实例**，并在
`viewWillAppear` 时重新触发一次 `sectionDataArray`，避免点到已销毁的上下文。

执行插件回调时做一次「上下文重定向」：临时把 `viewModel.controllerDelegate`
指向当前控制器，1 秒后确认仍是我们再还原，兼顾 push 与 present 两条路径。

### 3. 版本号从哪来

```
/var/jb/var/lib/dpkg/status          → Package / Name / Version
/var/jb/var/lib/dpkg/info/*.list      → dylib 路径 → 归属包
```

拿到 dylib 文件名后在 `.list` 里反查包名，再回 `status` 取版本。
结果会缓存到 `com.dpo.pluginnest` 偏好里，第二次启动直接命中。

沙盒读不到 dpkg、或插件是手动注入（没有 deb 包）时，显示「版本未知」，
可以手动补：

```xml
<!-- /var/mobile/Library/Preferences/com.dpo.pluginnest.overrides.plist -->
<dict>
    <key>DYYY.dylib</key>
    <dict>
        <key>name</key><string>DYYY</string>
        <key>version</key><string>1.2.3</string>
    </dict>
</dict>
```

### 4. 开关同步

```objc
item.isSwitchOn = enabled;      // 先写模型
item.switchChangedBlock(enabled); // 再回放插件逻辑
[item refreshCell];             // 让抖音原设置页的开关也跟着变
```

从插件页返回时重新抓取，插件自己改过的状态会覆盖回来，不存在两边不一致。

---

## 六、排查「入口没被收走」

列表为空时点「查看诊断」会列出本次扫描到的每一个设置项：

- `归属`：最终判定属于哪个插件（dylib 文件名）；
- `block`：`cellTappedBlock` 的 invoke 落在哪个镜像；
- `class`：`cellControllerClass` / `bizViewModelClass`；
- `已收纳 / 未识别 / 重复`：判定结果。

右上角「复制」可把整份诊断拷到剪贴板。排查时优先看两类：

1. **列表里根本没有这个入口** → 它不在 `sectionDataArray` 里，属于非标准注入（自定义 View），当前版本不支持；
2. **有这个入口但「未识别」** → 看 `block` / `class` 是否为空：
   - 都为空：这个 item 是纯数据行，只能靠 dylib 文件名兜底，可在 `overrides` 里补，或把 dylib 名告诉开发者；
   - 有值但路径奇怪：把路径发出来，补进镜像判定规则即可。

## 七、运行日志（排查用）

收纳页标题连点五次进入运行日志（诊断页左上角也有「日志」）：

- **导出**：调系统文稿选择器，把 `.log` 文件存到「文件」或分享；
- **复制**：整份日志进剪贴板；
- 日志同时落盘在 `/var/mobile/Library/Preferences/com.dpo.pluginnest.log`
  （写不进去时退回 App 临时目录，页面底部会显示真实路径）。

记录内容：

```
BOOT    版本号、pid
HOOK    挂了哪些类/方法、失败原因
MAINVM  主设置页 VM 实例登记
HARVEST 每轮扫描的 VM / section 数 / 收走数量
ITEM    每个设置项的标题、id、block 镜像、是否宿主、判定结果
RESCAN  补扫前后功能数与收走次数、是否 reload
ACT     点击了哪个功能、用什么上下文、是否执行成功
TOGGLE  开关切换
PKG     dylib → 包名/版本解析结果
CRASH   未捕获异常 + 调用栈
```

## 八、调试

```bash
# 终端启动抖音并打开日志
DPO_DEBUG=1 open com.ss.iphone.ugc.Aweme
# 或
killall -9 Aweme; DPO_DEBUG=1 /var/jb/usr/bin/Aweme
```

日志前缀 `[PluginNest]`，会打印：

- 挂在哪个类的 `sectionDataArray`
- 本轮收纳了多少条
- 执行插件回调 / 开关回调时的异常

---

## 九、已知限制

1. **只处理走 `AWESettingBaseViewModel.sectionDataArray` 的入口**。极少数插件直接把
   自定义 View 塞进设置页（不走 item 模型），这类无法摘取。
2. **深层索引依赖标准设置页模型**：插件子页若不是用 `AWESettingSectionModel` 构建，
   子功能不会进索引（顶层入口仍可正常收纳与搜索）。
3. **深层项点击只打开插件页、不定位到行**：`locatorPage/locatorIndex/locatorTrail` 已落盘，
   定位与高亮还没接（P3）。
4. **静态索引未启用**：插件页从未打开过时，只有顶层入口可搜；要覆盖插件内部功能名需加
   dylib 字符串扫描（P2）。
5. **版本号依赖 dpkg 可读**；沙盒限制或手动安装时显示「版本未知」，可用 overrides 补。
6. 插件把自己的入口做成「纯展示、无 block、无 identifier」时无法判定归属，会留在原位置。

---

## 十、目录结构

```
DYstorage/
├── Tweak.x                          # 唯一 hook 点 + 安装调度
├── DPOCommon.h                      # 抖音私有类声明（只声明，不引用类符号）
├── DPORuntime.{h,m}                 # 类查找 / 顶层 VC / block 镜像 / 拼音 / 触感
├── DPOTheme.{h,m}                   # 视觉常量
├── DPOModel.{h,m}                   # 功能 / 插件 / 仓库 / 搜索排序
├── DPOPackageResolver.{h,m}         # dylib → 包名 + 版本
├── DPOHarvester.{h,m}               # 摘取、分组、入口行、执行回调
├── DPOViews.{h,m}                   # 功能行 / 分组头 / 空状态 / Toast
├── DPODiagnostics.{h,m}             # 归属诊断列表（排查漏收）
├── DPOLogCenter.{h,m}               # 运行日志（缓冲 + 落盘 + 崩溃捕获）
├── DPOLogViewController.{h,m}       # 日志查看 / 分享
├── DPOOrganizerViewController.{h,m} # 收纳页
└── DPOPluginDetailViewController.{h,m} # 插件详情（当前未被引用）
```
