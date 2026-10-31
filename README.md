# DYStorage（抖音插件收纳）

DYStorage 是注入抖音的 Theos tweak。它把兼容第三方插件散落在抖音“设置”主页的入口收进一个单独的“插件收纳”入口，同时保留原插件的点击回调，因此点进收纳页后仍然打开各插件原本的设置页面。

这个项目的目标是**整理插件设置**，不是修改抖音官方“收藏夹”或上传任何作品数据。

## 做了什么

- 在抖音设置主页插入一个原生样式的“插件收纳” section；使用稳定的 identifier 防止重复插入。
- 识别 DYYY（`huami1314/DYYY`当前都使用的独立 `DYYY` section）以及一组常见插件根入口。
- 收纳 DYYY 等已知插件的**单项根入口 section**；对于混在普通 section 里的已知插件项，只有能安全复制原 section 时才剔除目标项，绝不原地改写其他 tweak 的模型。
- 复用被收纳 `AWESettingItemModel` 的原始 `cellTappedBlock`，不需要猜测 DYYY 的设置控制器类名。
- 提供可实际调用的运行时注册 API，供没有标准设置 section 的插件主动接入。
- 收纳页顶部提供参考 DYYY 样式的聚合搜索框，可搜索已收纳插件的功能名称和分类：来源是审核过的静态目录，加上本机学到的插件页面数据；未安装的插件不会出现在结果中。
- 聚合搜索目录来自开发者审核后的扫描数据，只保存功能名称与所属分类，不保存用户设置值或账号数据。
- 收纳页底部显示版本、作者、版权和可点击的 GitHub 仓库地址。
- 启动后在主线程延迟安装 Hook，让 `%orig` 通常能看到 DYYY 已经插入的 section；另有仅匹配“单项根入口”的 section-model 兜底，以处理后装载 Hook 追加的同类入口。
- 首次打开某个已收纳插件页时，DYStorage 会顺带记录该页的功能名称与分组（上限 400 条，按标题去重），因此即使插件没有静态目录，收纳后点开一次也能被聚合搜索到；学习结果只写入本机 `NSUserDefaults` 的 `DYStorageRuntimeCatalogV1`。
- 设置主页里发现疑似第三方插件入口时（单项 section、标题不是内置名单、也不是账号/通用/隐私一类系统分组），收纳页会把它们列在「发现的插件入口」下，点一下即确认收纳；未确认的入口一律留在原位，不改动其他 tweak 的模型。
- 搜索栏按宿主背景亮度自适应深浅配色，跟随抖音自身的深浅色开关与系统外观切换，不再固定使用系统语义色。

正常使用时不会持续扫描 `UIWindow` / `UIView`，也不拦截悬浮球、不模糊匹配普通页面文本、不接管抖音的收藏网络请求。项目保留了显式启动的开发者扫描器，用于插件升级后的目录适配；其 UI 默认隐藏。

如需重新采集目录，可在抖音的 `NSUserDefaults` 中临时设置 `DYStorageDeveloperMode=YES`，重启抖音后“开发者扫描”入口才会显示。采集完成后删除该键或设为 `NO` 即可恢复隐藏。

## 兼容性与边界

抖音的 `AWESettingsViewModel`、`AWESettingItemModel`、`AWESettingSectionModel` 都是私有实现，任何抖音版本升级都可能改变它们。DYStorage 在运行时检查类和 selector，缺少目标时不会安装对应 Hook；这避免了直接崩溃，但不能替代真机验证。

目前主页判定优先看“账号 / 账户 / Account / General”等根设置 section，也会尝试 section identifier 中的 `account` / `setting` 组合；此外，只要主页存在已知插件的单项根入口 section，同样认定为设置主页，避免抖音调整分组标题后收纳入口静默消失。这与 `huami1314/DYYY` 的“账号”保护一致，但比无条件向所有 `AWESettingsViewModel` 注入更保守。

默认被动收纳名单在 [`Tweak.xm`](Tweak.xm) 的 `DYStorageKnownPluginTitles` 中。高级用户可在进程的 `NSUserDefaults` 中以字符串数组设置 `DYStorageTargetPluginTitles`，添加自己已验证的**设置根入口标题**；不要填写泛化词，例如“设置”或“助手”。

## 插件发现、索引与外观

三个机制都围绕同一个前提：DYStorage 不猜类名、不改写别人的模型，只在用户确认或用户实际打开页面之后才记录数据。

- 收纳标题的来源依次是内置名单 `DYStorageKnownPluginTitles`、`NSUserDefaults` 里的 `DYStorageTargetPluginTitles`，以及用户在收纳页点选的候选入口；点选结果写入 `DYStorageConfirmedPluginTitles`，重启抖音后按普通插件处理。
- 候选入口只是建议，不会自动搬走任何 section。判定条件见 `DYStorageSectionLooksLikePluginEntryCandidate`：单项 section、item 带有 `cellTappedBlock`、标题不在确认名单内、header 不是系统分组；同一批最多展示 24 条。
- 学习索引在用户从收纳页进入插件页时启动，窗口 8 秒，插件页重新渲染会顺延 4 秒，最多记录 400 条。回到收纳页或点开另一个入口会立刻结束这次采集，收纳页自身的数据永远不会被计入。
- 搜索栏的深浅色取宿主 `backgroundColor` 的亮度（`0.2126r + 0.7152g + 0.0722b < 0.5` 判为深色），拿不到颜色时才退回 `traitCollection`，原因是抖音的深浅色开关独立于 iOS 外观。

删除 `DYStorageRuntimeCatalogV1` 或重装即可清空学习结果；静态目录仍然优先，学习到的同名标题不会覆盖审核过的条目。

## 给插件作者的主动接入方式

首选注册一个负责展示你自己设置页的 block。不要把控制器或 view model 对象保存到全局；只在用户点击时创建或展示它。

DYStorage 没有要求其他 tweak 链接它。下面的 Logos / Objective-C 示例通过运行时调用，DYStorage 未安装时会自然跳过：

```objc
%ctor {
    Class managerClass = NSClassFromString(@"DYStorageManager");
    SEL sharedSelector = NSSelectorFromString(@"sharedManager");
    if (!managerClass || ![managerClass respondsToSelector:sharedSelector]) return;

    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector);
    SEL registerSelector = NSSelectorFromString(@"registerActionWithIdentifier:title:version:action:");
    if (![manager respondsToSelector:registerSelector]) return;

    NSString *identifier = @"com.example.my-tweak";
    NSString *title = @"我的插件";
    NSString *version = @"1.0.0";
    void (^openSettings)(void) = ^{
        // 在主线程创建并展示你的设置控制器。
    };

    NSMethodSignature *signature = [manager methodSignatureForSelector:registerSelector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = manager;
    invocation.selector = registerSelector;
    [invocation setArgument:&identifier atIndex:2];
    [invocation setArgument:&title atIndex:3];
    [invocation setArgument:&version atIndex:4];
    [invocation setArgument:&openSettings atIndex:5];
    [invocation invoke];
}
```

可用的接口定义见 [`DYStorageManager.h`](DYStorageManager.h)：

- `registerActionWithIdentifier:title:version:action:`
- `registerControllerWithIdentifier:title:version:controller:`
- `registerActionWithTitle:version:action:`（兼容没有稳定 identifier 的旧集成）
- `unregisterPluginWithIdentifier:`

## 构建

本地需要 Theos、iOS SDK 与 `ldid`。默认是 rootless 方案：

```sh
make package SCHEME=rootless
```

三种安装方式分别构建：

```sh
make package SCHEME=rootful     # iphoneos-arm
make package SCHEME=rootless    # iphoneos-arm64
make package SCHEME=roothide    # iphoneos-arm64e (RootHide), needs roothide/theos
```

`control` 里的 `Version` 是版本的唯一来源：Makefile 在编译时把它注入 `-DDYSTORAGE_VERSION_STRING`，因此包内声明与设置页底部显示的版本始终一致。发新版只需改这一处，并同步 `RELEASE_NOTES.md`。

`FINALPACKAGE=1` 用于去掉包名后的修订后缀，本地调试可省略。

## 发布

推送 `v*` 标签会触发 GitHub Actions，一次构建三个方案的 `.deb` 与一个独立 `.dylib`，校验后自动创建 Release 并上传；也可以在 Actions 页面手动触发，产物作为 artifact 保留 30 天。

CI 打包前运行 `python3 scripts/validate_catalog.py` 校验聚合搜索目录（JSON 可解析、插件名与 `DYStorageKnownPluginTitles` 一致、无空标题，并报告重复标题），打包后运行 `.github/scripts/verify_packages.py` 核对三个包的架构、版本、依赖与 dylib 切片。版本解析在 tag 构建时取标签名，手动触发时取 `control` 的主版本号加运行编号。

## 目录维护

`DYStorageSearchCatalog.m` 是内置开发者扫描器导出的静态目录，不是运行时抓取。第三方插件更新后，用扫描器重新导出，替换该文件里的 JSON 串，再跑一次 `scripts/validate_catalog.py`；若目录里的插件名发生变化，同步更新 `Tweak.xm` 中的 `DYStorageKnownPluginTitles`。

## 参考

实现思路参考了 [huami1314/DYYY](https://github.com/huami1314/DYYY) 的设置入口 Hook：两者都会构建独立的 `AWESettingSectionModel` 并插入 `AWESettingsViewModel.sectionDataArray` 的首位。DYStorage 没有复制其设置页代码；它只保留已生成 entry 的原始回调。

本项目采用 [MIT License](LICENSE)。
