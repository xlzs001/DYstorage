

#import "DPOHarvester.h"
#import "DPORuntime.h"
#import "DPOTheme.h"
#import "DPOViews.h"
#import "DPOPackageResolver.h"
#import "DPOOrganizerViewController.h"
#import "DPODiagnostics.h"
#import "DPOLogCenter.h"
#import <dlfcn.h>
#import <objc/runtime.h>

#pragma mark - 类缓存

static Class DPOItemClass(void) {
    static Class cls = Nil;
    if (cls == Nil) cls = DPOLookupClass("AWESettingItemModel");
    return cls;
}

static Class DPOSectionClass(void) {
    static Class cls = Nil;
    if (cls == Nil) cls = DPOLookupClass("AWESettingSectionModel");
    return cls;
}

static BOOL DPOIsItem(id obj) {
    Class cls = DPOItemClass();
    return (cls != Nil && obj != nil && [obj isKindOfClass:cls]);
}

static BOOL DPOIsSection(id obj) {
    Class cls = DPOSectionClass();
    return (cls != Nil && obj != nil && [obj isKindOfClass:cls]);
}

static BOOL DPOPageOwnedByHostSettings(AWESettingBaseViewModel *vm) {
    if (vm == nil) return NO;
    @try {
        id delegate = [vm controllerDelegate];
        if (delegate == nil) return NO;
        NSString *name = NSStringFromClass([delegate class]);
        return name.length > 0 && [name containsString:@"SettingsTableViewController"];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

#pragma mark - Identifier 前缀提示

static NSMutableDictionary<NSString *, NSString *> *DPOPrefixHints(void) {
    static NSMutableDictionary *hints = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hints = [NSMutableDictionary dictionary];
    });
    return hints;
}

static NSString *DPOPrefixForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return nil;

    if ([identifier containsString:@"."]) {
        NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
        if (parts.count >= 2 && [parts[0] length] > 0 && [parts[1] length] > 0) {
            return [NSString stringWithFormat:@"%@.%@", parts[0], parts[1]];
        }
    }

    NSMutableString *prefix = [NSMutableString string];
    for (NSUInteger i = 0; i < identifier.length && prefix.length < 8; i++) {
        unichar c = [identifier characterAtIndex:i];
        if (c >= 'A' && c <= 'Z') {
            [prefix appendFormat:@"%C", c];
        } else {
            break;
        }
    }
    return prefix.length >= 2 ? prefix : nil;
}

static void DPORegisterPrefixHint(NSString *identifier, NSString *image) {
    NSString *prefix = DPOPrefixForIdentifier(identifier);
    if (prefix.length == 0 || image.length == 0) return;
    @synchronized (DPOPrefixHints()) {
        if (DPOPrefixHints()[prefix] == nil) DPOPrefixHints()[prefix] = image;
    }
}

static NSString *DPOHintForIdentifier(NSString *identifier) {
    NSString *prefix = DPOPrefixForIdentifier(identifier);
    if (prefix.length == 0) return nil;
    @synchronized (DPOPrefixHints()) {
        return DPOPrefixHints()[prefix];
    }
}

#pragma mark - 已安装插件名兜底

static NSString *DPOMatchInstalledTweak(NSString *title, NSString *identifier) {
    static NSDictionary<NSString *, NSString *> *nameMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
        NSArray<NSString *> *dirs = @[
            @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
            @"/var/jb/usr/lib/TweakInject",
            @"/Library/MobileSubstrate/DynamicLibraries",
            @"/usr/lib/TweakInject",
        ];

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *dir in dirs) {
            NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:NULL];
            for (NSString *file in files) {
                if (![file.pathExtension isEqualToString:@"dylib"]) continue;
                NSString *stem = file.stringByDeletingPathExtension.lowercaseString;
                if (stem.length < 3) continue;
                if ([stem containsString:@"substrate"] || [stem containsString:@"ellekit"] ||
                    [stem containsString:@"libhooker"] || [stem containsString:@"pluginnest"]) {
                    continue;
                }
                NSString *fullPath = [dir stringByAppendingPathComponent:file];
                if (map[stem] == nil) map[stem] = fullPath;
            }
        }
        nameMap = map;
    });

    NSString *titleLower = title.lowercaseString ?: @"";
    NSString *identifierLower = identifier.lowercaseString ?: @"";

    if (titleLower.length >= 2 && nameMap[titleLower] != nil) return nameMap[titleLower];

    for (NSString *stem in nameMap) {
        if (stem.length < 4) continue;
        if ([titleLower containsString:stem]) return nameMap[stem];
        if (identifierLower.length > 0 && [identifierLower containsString:stem]) return nameMap[stem];
    }
    return nil;
}

#pragma mark - 激活上下文（用于子页面功能索引）

static NSUInteger DPOLastScanCount = 0;
static NSUInteger DPOHarvestChangeCount = 0;
static NSTimeInterval DPOLastItemLogTime = 0;
static NSMutableSet<NSString *> *DPOSeenItemKeys = nil;
static NSMutableSet<NSString *> *DPOCollectedIdentifiers = nil;
static __weak AWESettingBaseViewModel *DPOLastProcessedViewModel = nil;
static NSArray *DPOLastProcessedSections = nil;
static BOOL DPOHasBootstrapped = NO;
static BOOL DPOForceNextHarvest = NO;
static BOOL DPOSessionHarvestDone = NO;   
static NSString *const DPOKnownIdentifiersKey = @"DPOKnownIdentifiers";
static NSMutableSet<NSString *> *DPOKnownIdentifiers = nil;   
static __weak AWESettingBaseViewModel *DPOCachedViewModel = nil;
static NSString *DPOCachedSignature = nil;
static NSTimeInterval DPOCachedAt = 0;
static NSArray *DPOCachedResult = nil;

static NSString *DPOActiveImage = nil;
static NSTimeInterval DPOActiveDeadline = 0;
static NSInteger DPOActiveToken = 0;

static void DPOBeginActivation(NSString *image) {
    if (image.length == 0) return;
    DPOActiveImage = [image copy];
    
    DPOActiveDeadline = [NSDate date].timeIntervalSince1970 + 300.0;
    DPOActiveToken += 1;
    NSInteger token = DPOActiveToken;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != DPOActiveToken) return;
        DPOActiveImage = nil;
        DPOActiveDeadline = 0;
    });
}

static NSString *DPOActivePluginImage(void) {
    if (DPOActiveImage.length == 0) return nil;
    if ([NSDate date].timeIntervalSince1970 > DPOActiveDeadline) return nil;
    return DPOActiveImage;
}

#pragma mark - 崩溃隔离

static NSString *const DPOGuardActiveKey = @"DPOGuardActiveKey";
static NSString *const DPOGuardActiveAt = @"DPOGuardActiveAt";
static NSString *const DPOGuardQuarantine = @"DPOGuardQuarantine";
static NSString *const DPOGuardBuildKey = @"DPOGuardBuild";

static NSMutableArray<NSString *> *DPOQuarantineList(void) {
    id stored = [[NSUserDefaults standardUserDefaults] arrayForKey:DPOGuardQuarantine];
    if (![stored isKindOfClass:[NSArray class]]) return [NSMutableArray array];
    NSMutableArray *list = [NSMutableArray array];
    for (id item in (NSArray *)stored) {
        if ([item isKindOfClass:[NSString class]] && [item length] > 0) [list addObject:item];
    }
    return list;
}

static BOOL DPOIsQuarantined(NSString *key) {
    if (key.length == 0) return NO;
    return [DPOQuarantineList() containsObject:key];
}

static void DPOSetQuarantined(NSString *key, BOOL quarantined) {
    if (key.length == 0) return;

    NSMutableArray *list = DPOQuarantineList();
    BOOL has = [list containsObject:key];
    if (quarantined && !has) [list addObject:key];
    if (!quarantined && has) [list removeObject:key];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:list forKey:DPOGuardQuarantine];
    [defaults synchronize];
}

static void DPOGuardBeginActivation(NSString *key) {
    if (key.length == 0) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:key forKey:DPOGuardActiveKey];
    [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:DPOGuardActiveAt];
    [defaults synchronize];
}

static void DPOGuardEndActivation(NSString *key) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString *active = [defaults stringForKey:DPOGuardActiveKey];
    if (active.length == 0) return;
    
    if (key.length > 0 && ![active isEqualToString:key]) return;

    [defaults removeObjectForKey:DPOGuardActiveKey];
    [defaults removeObjectForKey:DPOGuardActiveAt];
    [defaults synchronize];
}

static void DPORecoverQuarantine(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    
    
    NSString *build = [defaults stringForKey:DPOGuardBuildKey];
    if (![build isEqualToString:DPOBuildVersion]) {
        [defaults removeObjectForKey:DPOGuardQuarantine];
        [defaults setObject:DPOBuildVersion forKey:DPOGuardBuildKey];
        [defaults synchronize];
        if (build.length > 0) {
            DPOLogEvent(@"GUARD", @"版本 %@ → %@，清空隔离名单", build, DPOBuildVersion);
        }
    }

    NSString *active = [defaults stringForKey:DPOGuardActiveKey];
    double at = [defaults doubleForKey:DPOGuardActiveAt];
    [defaults removeObjectForKey:DPOGuardActiveKey];
    [defaults removeObjectForKey:DPOGuardActiveAt];
    [defaults synchronize];

    if (active.length == 0) return;

    DPOSetQuarantined(active, YES);
    DPOLogEvent(@"GUARD", @"上次执行 %@ 后进程终止（%.0f 秒前），已加入隔离名单",
                active, at > 0 ? [NSDate date].timeIntervalSince1970 - at : 0);
}

#pragma mark - 工具

static BOOL DPOSectionReplaceItems(AWESettingSectionModel *section, NSArray *items) {
    if (section == nil || items == nil) return NO;

    NSArray *current = section.itemArray;
    if ([current isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *mutable = (NSMutableArray *)current;
        [mutable removeAllObjects];
        [mutable addObjectsFromArray:items];
        return YES;
    }
    if ([section respondsToSelector:@selector(setItemArray:)]) {
        section.itemArray = items;
        return YES;
    }
    @try {
        [section setValue:items forKey:@"itemArray"];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static AWESettingItemModel *DPOFindDonorItem(NSArray *sections) {
    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) continue;
        AWESettingSectionModel *section = (AWESettingSectionModel *)sectionObject;
        NSArray *items = section.itemArray;
        if (![items isKindOfClass:[NSArray class]]) continue;

        for (id itemObject in items) {
            if (!DPOIsItem(itemObject)) continue;
            AWESettingItemModel *item = (AWESettingItemModel *)itemObject;
            if (item.cellTappedBlock != nil && item.switchChangedBlock == nil &&
                DPOSafeString(item.title).length > 0) {
                return item;
            }
        }
    }
    return nil;
}

static DPOFeature *DPOMakeFeature(AWESettingItemModel *item,
                                  NSString *image,
                                  AWESettingSectionModel *section,
                                  AWESettingBaseViewModel *vm,
                                  BOOL isDeep) {
    if (item == nil || image.length == 0) return nil;

    NSString *title = DPOSafeString(item.title);
    if (title.length == 0) title = DPOSafeString(item.identifier);
    if (title.length == 0) return nil;

    DPOFeature *feature = [[DPOFeature alloc] init];
    feature.title = title;
    feature.identifier = DPOSafeString(item.identifier);
    feature.subtitle = DPOSafeString(item.detail).length > 0 ? DPOSafeString(item.detail)
                                                             : DPOSafeString(item.subTitle);
    feature.sectionTitle = DPOSafeString(section.sectionHeaderTitle);
    feature.pluginImage = image;
    feature.item = isDeep ? nil : item;
    feature.viewModel = isDeep ? nil : vm;
    feature.isDeep = isDeep;
    
    
    feature.isSwitch = isDeep ? NO : (item.switchChangedBlock != nil && item.cellTappedBlock == nil);
    feature.isOn = isDeep ? NO : item.isSwitchOn;

    NSString *key = feature.identifier.length > 0
                        ? [NSString stringWithFormat:@"%@|%@", image, feature.identifier]
                        : [NSString stringWithFormat:@"%@|%@", image, title];
    feature.key = key;

    [feature refreshSearchBlob];
    DPORegisterPrefixHint(feature.identifier, image);
    return feature;
}

#pragma mark - DPOHarvester

@interface DPOHarvester ()
+ (NSArray *)dpo_processMain:(AWESettingBaseViewModel *)vm sections:(NSArray *)sections force:(BOOL)force;
+ (AWESettingItemModel *)dpo_makeEntryItemWithPlugins:(NSUInteger)pluginCount
                                             sections:(NSArray *)sections
                                            viewModel:(AWESettingBaseViewModel *)vm;
+ (void)dpo_insertEntrySectionInto:(NSMutableArray *)keptSections viewModel:(AWESettingBaseViewModel *)vm;

// 激活链（定义在文件后半段，主页面/激活处要先用到）
static void DPOActivationTrailReset(void);
static void DPOActivationTrailPush(NSString *title);
static NSArray<NSString *> *DPOActivationTrailSnapshot(void);
+ (void)dpo_openPluginPageForDeepFeature:(DPOFeature *)feature from:(UIViewController *)host;
+ (void)dpo_openStreakHelperIfNeeded:(DPOFeature *)feature from:(UIViewController *)top;
+ (DPODiagnosticEntry *)dpo_diagnosticForItem:(AWESettingItemModel *)item
                                      section:(AWESettingSectionModel *)section
                                        owner:(NSString *)owner;
+ (BOOL)dpo_looksLikeVersion:(NSString *)text;
+ (BOOL)dpo_isUsablePluginTitle:(NSString *)title;
+ (NSArray *)handleSubPageViewModel:(AWESettingBaseViewModel *)vm sections:(NSArray *)sections;
+ (void)mergeNestedFeatures:(NSArray<DPOFeature *> *)features;
+ (NSString *)dpo_iconNameForFeatures:(NSArray<DPOFeature *> *)features;
+ (NSArray *)dpo_dropEmptySections:(NSArray *)sections;
@end

@implementation DPOHarvester

+ (void)resetScanCache {
    [[self dpo_knownIdentifiers] removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:DPOKnownIdentifiersKey];
    DPOSessionHarvestDone = NO;
    DPOForceNextHarvest = YES;
    DPOCachedResult = nil;
    DPOCachedSignature = nil;
    DPOCachedViewModel = nil;
    DPOLogEvent(@"HARVEST", @"已清空扫描缓存，下次取数据会重新扫描");
}

+ (void)recoverQuarantineIfNeeded {
    DPORecoverQuarantine();
}

+ (NSUInteger)lastScanCount {
    return DPOLastScanCount;
}

+ (NSUInteger)harvestChangeCount {
    return DPOHarvestChangeCount;
}

+ (id)lastProcessedViewModel {
    return DPOLastProcessedViewModel;
}

+ (NSArray *)lastProcessedSections {
    return DPOLastProcessedSections;
}

+ (NSUInteger)countThirdPartyItemsInSections:(NSArray *)sections {
    if (![sections isKindOfClass:[NSArray class]]) return 0;

    NSUInteger count = 0;
    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) continue;
        NSArray *items = ((AWESettingSectionModel *)sectionObject).itemArray;
        if (![items isKindOfClass:[NSArray class]]) continue;

        for (id itemObject in items) {
            if (!DPOIsItem(itemObject)) continue;
            AWESettingItemModel *item = (AWESettingItemModel *)itemObject;
            if ([DPOSafeString(item.identifier) hasPrefix:DPOEntryIdentifier]) continue;
            if (DPOPluginImageForItem(item).length > 0) {
                count += 1;
                DPOLogEvent(@"LEFTOVER", @"残留：%@ | id=%@", DPOSafeString(item.title),
                            DPOSafeString(item.identifier));
            }
        }
    }
    return count;
}

+ (NSUInteger)collectAndRemoveThirdPartyItemsInSections:(NSArray *)sections {
    if (![sections isKindOfClass:[NSArray class]]) return 0;

    NSMutableArray<DPOFeature *> *collected = [NSMutableArray array];
    NSUInteger removed = 0;

    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) continue;
        AWESettingSectionModel *section = (AWESettingSectionModel *)sectionObject;
        NSArray *items = section.itemArray;
        if (![items isKindOfClass:[NSArray class]] || items.count == 0) continue;

        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:items.count];
        BOOL changed = NO;

        for (id itemObject in items) {
            if (DPOIsItem(itemObject)) {
                AWESettingItemModel *item = (AWESettingItemModel *)itemObject;
                NSString *identifier = DPOSafeString(item.identifier);
                NSString *image = DPOPluginImageForItem(item);

                if (image.length > 0 && ![identifier hasPrefix:DPOEntryIdentifier]) {
                    DPOFeature *feature = DPOMakeFeature(item, image, section, nil, NO);
                    if (feature != nil) {
                        if (DPOCollectedIdentifiers == nil) DPOCollectedIdentifiers = [NSMutableSet set];
                        BOOL isNew = identifier.length == 0 ||
                                     ![DPOCollectedIdentifiers containsObject:identifier];
                        if (isNew) {
                            [collected addObject:feature];
                            removed += 1;
                            DPOLogEvent(@"LATE", @"补收入口：%@ → %@", feature.title,
                                        image.lastPathComponent);
                        }
                        
                        
                        if (identifier.length > 0) [DPOCollectedIdentifiers addObject:identifier];
                        changed = YES;   
                        continue;
                    }
                }
            }
            [kept addObject:itemObject];
        }

        if (changed) DPOSectionReplaceItems(section, kept);
    }

    if (collected.count > 0) [self mergeNestedFeatures:collected];
    return removed;
}

+ (NSUInteger)purgeThirdPartyItemsInSections:(NSArray *)sections {
    if (![sections isKindOfClass:[NSArray class]]) return 0;

    NSUInteger removed = 0;
    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) continue;
        AWESettingSectionModel *section = (AWESettingSectionModel *)sectionObject;
        NSArray *items = section.itemArray;
        if (![items isKindOfClass:[NSArray class]] || items.count == 0) continue;

        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:items.count];
        BOOL changed = NO;

        for (id itemObject in items) {
            if (DPOIsItem(itemObject)) {
                AWESettingItemModel *item = (AWESettingItemModel *)itemObject;
                NSString *identifier = DPOSafeString(item.identifier);
                if (![identifier hasPrefix:DPOEntryIdentifier] &&
                    DPOPluginImageForItem(item).length > 0) {
                    changed = YES;
                    removed += 1;
                    DPOLogEvent(@"PURGE", @"清除残留：%@ | id=%@",
                                DPOSafeString(item.title), identifier);
                    continue;
                }
            }
            [kept addObject:itemObject];
        }

        if (changed) DPOSectionReplaceItems(section, kept);
    }
    return removed;
}

+ (BOOL)dpo_looksLikeVersion:(NSString *)text {
    if (text.length == 0 || text.length > 24) return NO;
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^[vV]?[0-9]+(\\.[0-9]+)*(-[0-9A-Za-z.]+)?$"
                                                          options:0
                                                            error:NULL];
    });
    NSRange range = NSMakeRange(0, text.length);
    return [regex numberOfMatchesInString:text options:0 range:range] > 0;
}

+ (BOOL)dpo_isUsablePluginTitle:(NSString *)title {
    if (title.length < 2 || title.length > 24) return NO;

    static NSSet<NSString *> *blocked = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blocked = [NSSet setWithArray:@[
            @"设置", @"插件", @"插件设置", @"更多", @"入口", @"Settings", @"Plugin",
            @"确定", @"取消", @"返回", @"完成", @"编辑", @"删除", @"添加", @"开启", @"关闭",
            @"保存", @"重置", @"退出", @"登录", @"分享", @"复制", @"清空", @"搜索",
            @"版本", @"关于", @"帮助", @"反馈", @"主页", @"首页", @"我的", @"消息",
        ]];
    });
    if ([blocked containsObject:title]) return NO;
    if ([title hasPrefix:@"版本"]) return NO;

    // 纯数字 / 纯符号 / 版本号不是功能名。中文不算 alphanumeric，但也不是
    // 数字/标点/空白，所以这个循环对中文仍然返回 YES。
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    NSCharacterSet *punctuation = [NSCharacterSet punctuationCharacterSet];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSUInteger index = 0; index < title.length; index++) {
        unichar c = [title characterAtIndex:index];
        if ([digits characterIsMember:c]) continue;
        if ([punctuation characterIsMember:c]) continue;
        if ([whitespace characterIsMember:c]) continue;
        return YES;
    }
    return NO;
}

#pragma mark 主设置页

static NSString *DPOSectionsSignature(NSArray *sections) {
    if (![sections isKindOfClass:[NSArray class]]) return @"";
    NSUInteger itemCount = 0;
    NSString *firstIdentifier = @"";
    NSString *lastIdentifier = @"";

    for (id object in sections) {
        if (!DPOIsSection(object)) continue;
        NSArray *items = ((AWESettingSectionModel *)object).itemArray;
        if (![items isKindOfClass:[NSArray class]]) continue;
        itemCount += items.count;
        for (id itemObject in items) {
            if (!DPOIsItem(itemObject)) continue;
            NSString *identifier = DPOSafeString(((AWESettingItemModel *)itemObject).identifier);
            if (firstIdentifier.length == 0) firstIdentifier = identifier;
            lastIdentifier = identifier;
        }
    }
    return [NSString stringWithFormat:@"%lu|%lu|%@|%@",
            (unsigned long)sections.count, (unsigned long)itemCount,
            firstIdentifier, lastIdentifier];
}

+ (void)setForceNextHarvest:(BOOL)force {
    DPOForceNextHarvest = force;
}

+ (BOOL)hasBootstrapped {
    return DPOHasBootstrapped;
}

+ (BOOL)isCollectedIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    @synchronized (self) {
        return [DPOCollectedIdentifiers containsObject:identifier];
    }
}

+ (NSArray *)dpo_dropEmptySections:(NSArray *)sections {
    if (![sections isKindOfClass:[NSArray class]]) return sections;

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:sections.count];
    for (id object in sections) {
        if (DPOIsSection(object)) {
            NSArray *items = ((AWESettingSectionModel *)object).itemArray;
            if (![items isKindOfClass:[NSArray class]] || items.count == 0) continue;
        }
        [result addObject:object];
    }
    return [result copy];
}

+ (NSArray *)handleMainViewModel:(AWESettingBaseViewModel *)vm sections:(NSArray *)sections {
    if (![sections isKindOfClass:[NSArray class]] || sections.count == 0) return sections;

    // 回到主设置页 = 一次导航结束，激活链清零，避免下次定位重放历史路径。
    DPOActivationTrailReset();

    
    DPOSettingsViewModelKind kind = DPOClassifySettingsViewModel(vm);
    if (kind == DPOSettingsViewModelKindUnknown) return sections;
    if (kind == DPOSettingsViewModelKindSubPage) return sections;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *signature = DPOSectionsSignature(sections);

    
    
    
    
    if (!DPOForceNextHarvest && DPOHasBootstrapped &&
        vm == DPOCachedViewModel && DPOCachedResult != nil) {
        BOOL sameInput = [signature isEqualToString:DPOCachedSignature ?: @""];
        if (sameInput || now - DPOCachedAt < 2.0) {
            DPOCachedResult = [self dpo_dropEmptySections:DPOCachedResult];
            return DPOCachedResult;
        }
    }
    BOOL forceThisRound = DPOForceNextHarvest;
    DPOForceNextHarvest = NO;

    static BOOL inside = NO;
    
    
    
    if (inside) {
        if (DPOCachedResult != nil && DPOCachedViewModel == vm) return DPOCachedResult;
        return sections;
    }
    inside = YES;

    NSArray *result = sections;
    @try {
        result = [self dpo_processMain:vm sections:sections force:forceThisRound];
        result = [self dpo_dropEmptySections:result];
        DPOCachedViewModel = vm;
        DPOCachedSignature = signature;
        DPOCachedAt = now;
        DPOCachedResult = result;
        DPOHasBootstrapped = YES;
        DPOLastProcessedViewModel = vm;
        DPOLastProcessedSections = result;
    } @catch (NSException *exception) {
        NSLog(@"[PluginNest] 处理设置页异常：%@", exception.reason);
        DPOLogEvent(@"ERROR", @"处理设置页异常：%@ %@", exception.name, exception.reason);
    } @finally {
        inside = NO;
    }
    return result;
}

#pragma mark - 已知标识（判断“有没有新插件”）

+ (NSMutableSet<NSString *> *)dpo_knownIdentifiers {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:DPOKnownIdentifiersKey];
        DPOKnownIdentifiers = [NSMutableSet setWithArray:[saved isKindOfClass:[NSArray class]] ? saved : @[]];
    });
    return DPOKnownIdentifiers;
}

+ (NSSet<NSString *> *)dpo_currentIdentifiersInSections:(NSArray *)sections {
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) continue;
        NSArray *items = ((AWESettingSectionModel *)sectionObject).itemArray;
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (id itemObject in items) {
            if (!DPOIsItem(itemObject)) continue;
            NSString *identifier = DPOSafeString(((AWESettingItemModel *)itemObject).identifier);
            if (identifier.length == 0) continue;
            if ([identifier hasPrefix:DPOEntryIdentifier]) continue;
            [identifiers addObject:identifier];
        }
    }
    return identifiers;
}

+ (void)dpo_rememberIdentifiers:(NSSet<NSString *> *)identifiers {
    if (identifiers.count == 0) return;
    NSMutableSet *known = [self dpo_knownIdentifiers];
    NSUInteger before = known.count;
    [known unionSet:identifiers];
    if (known.count == before) return;

    NSArray *array = [known allObjects];
    if (array.count > 600) {
        array = [array subarrayWithRange:NSMakeRange(array.count - 600, 600)];
    }
    [[NSUserDefaults standardUserDefaults] setObject:array forKey:DPOKnownIdentifiersKey];
}

+ (void)dpo_insertEntrySectionInto:(NSMutableArray *)keptSections viewModel:(AWESettingBaseViewModel *)vm {
    if (keptSections == nil) return;

    DPOFeatureStore *store = [DPOFeatureStore shared];
    AWESettingItemModel *entryItem = [self dpo_makeEntryItemWithPlugins:store.pluginCount
                                                              sections:keptSections
                                                             viewModel:vm];
    if (entryItem == nil) return;

    Class sectionClass = DPOSectionClass();
    if (sectionClass == Nil) return;

    AWESettingSectionModel *container = (AWESettingSectionModel *)[[sectionClass alloc] init];
    @try {
        // 给入口单独起一个段，段头写插件名——否则光秃秃一行夹在「账号」「通用」之间很突兀。
        // 只有标题不够：抖音的段头高度取自 sectionHeaderHeight，为 0 时整个 header 不渲染。
        container.sectionHeaderTitle = @"DYstorage";
        container.sectionHeaderHeight = 30.0;
        container.itemArray = @[ entryItem ];
    } @catch (__unused NSException *exception) {
    }
    if (container.itemArray.count > 0) {
        [keptSections insertObject:container atIndex:0];
    }
}

+ (NSArray *)dpo_processMain:(AWESettingBaseViewModel *)vm sections:(NSArray *)sections force:(BOOL)force {
    NSMutableArray *keptSections = [NSMutableArray arrayWithCapacity:sections.count];
    NSMutableArray<DPOFeature *> *collected = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];

    
    
    
    NSSet<NSString *> *currentIdentifiers = [self dpo_currentIdentifiersInSections:sections];
    BOOL hasNewIdentifier = NO;
    if (DPOSessionHarvestDone) {
        NSSet *known = [self dpo_knownIdentifiers];
        for (NSString *identifier in currentIdentifiers) {
            if (![known containsObject:identifier]) {
                hasNewIdentifier = YES;
                break;
            }
        }
    }

    
    
    if (DPOSessionHarvestDone && !force && !hasNewIdentifier) {
        NSMutableArray *quick = [NSMutableArray arrayWithCapacity:sections.count];
        for (id object in sections) {
            if (!DPOIsSection(object)) {
                [quick addObject:object];
                continue;
            }
            AWESettingSectionModel *section = (AWESettingSectionModel *)object;
            NSArray *items = section.itemArray;
            if (![items isKindOfClass:[NSArray class]] || items.count == 0) continue;

            NSMutableArray *remain = [NSMutableArray arrayWithCapacity:items.count];
            BOOL changed = NO;
            for (id itemObject in items) {
                if (DPOIsItem(itemObject)) {
                    NSString *identifier = DPOSafeString(((AWESettingItemModel *)itemObject).identifier);
                    if ([identifier hasPrefix:DPOEntryIdentifier]) {
                        changed = YES;
                        continue;
                    }
                    if (identifier.length > 0 && [self isCollectedIdentifier:identifier]) {
                        changed = YES;
                        continue;
                    }
                }
                [remain addObject:itemObject];
            }
            if (changed) DPOSectionReplaceItems(section, remain);
            if (remain.count > 0) [quick addObject:section];
        }

        [self dpo_insertEntrySectionInto:quick viewModel:vm];
        DPOLogEvent(@"HARVEST", @"快速过滤：%lu 段（本会话已扫过，不重新收集）",
                    (unsigned long)quick.count);
        return [quick copy];
    }

    [[DPODiagnostics shared] reset];
    DPOLastScanCount = 0;

    @try {
        id delegate = [vm controllerDelegate];
        [DPODiagnostics shared].context = [NSString stringWithFormat:@"VM: %@\nDelegate: %@",
                                           NSStringFromClass([vm class]),
                                           delegate != nil ? NSStringFromClass([delegate class]) : @"(nil)"];
    } @catch (__unused NSException *exception) {
    }

    DPOLogEvent(@"HARVEST", @"开始扫描：VM=%@ sections=%lu",
                NSStringFromClass([vm class]), (unsigned long)sections.count);

    
    NSTimeInterval itemLogNow = [NSDate date].timeIntervalSince1970;
    BOOL verboseItems = (itemLogNow - DPOLastItemLogTime > 1.0) || DPOLogEnabled();
    if (verboseItems) DPOLastItemLogTime = itemLogNow;

    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) {
            [keptSections addObject:sectionObject];
            continue;
        }

        AWESettingSectionModel *section = (AWESettingSectionModel *)sectionObject;
        NSString *sectionOwner = DPOAssociatedOwner(section);
        NSArray *items = section.itemArray;
        if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
            [keptSections addObject:section];
            continue;
        }

        NSMutableArray *keptItems = [NSMutableArray arrayWithCapacity:items.count];
        BOOL changed = NO;

        for (id itemObject in items) {
            if (!DPOIsItem(itemObject)) {
                if (itemObject != nil && ![itemObject isKindOfClass:[NSString class]]) {
                    DPODiagnosticEntry *other = [[DPODiagnosticEntry alloc] init];
                    other.title = [NSString stringWithFormat:@"(非标准) %@",
                                   NSStringFromClass([itemObject class])];
                    other.itemClass = NSStringFromClass([itemObject class]);
                    other.section = DPOSafeString(section.sectionHeaderTitle);
                    other.decision = @"非标准类型";
                    [[DPODiagnostics shared] addEntry:other];
                }
                [keptItems addObject:itemObject];
                continue;
            }

            AWESettingItemModel *item = (AWESettingItemModel *)itemObject;
            NSString *identifier = DPOSafeString(item.identifier);
            DPOLastScanCount += 1;

            
            if ([identifier hasPrefix:DPOEntryIdentifier]) {
                changed = YES;
                continue;
            }

            BOOL hostOwned = DPOItemIsHostOwned(item);

            NSString *image = DPOPluginImageForItem(item);
            if (image.length == 0 && !hostOwned && identifier.length > 0) {
                image = DPOHintForIdentifier(identifier);
            }
            if (image.length == 0 && !hostOwned) {
                image = DPOMatchInstalledTweak(DPOSafeString(item.title), identifier);
            }
            
            if (image.length == 0 && !hostOwned && sectionOwner.length > 0) {
                image = sectionOwner;
            }

            DPODiagnosticEntry *diagnostic = [self dpo_diagnosticForItem:item
                                                                  section:section
                                                                    owner:image];
            diagnostic.itemClass = NSStringFromClass([item class]);

            
            
            if (DPOSeenItemKeys == nil) DPOSeenItemKeys = [NSMutableSet set];
            NSString *seenKey = [NSString stringWithFormat:@"%@|%@",
                                 DPOSafeString(item.title), identifier];
            if (![DPOSeenItemKeys containsObject:seenKey]) {
                [DPOSeenItemKeys addObject:seenKey];
                DPOLogEvent(@"SEEN", @"%@ | id=%@ | owner=%@ | block=%@ | host=%@",
                            DPOSafeString(item.title), identifier,
                            image.length > 0 ? image.lastPathComponent : @"-",
                            diagnostic.blockImage.lastPathComponent ?: @"-",
                            hostOwned ? @"Y" : @"N");
            }

            if (image.length == 0) {
                diagnostic.decision = @"未识别";
                [[DPODiagnostics shared] addEntry:diagnostic];
                if (verboseItems) {
                    DPOLogEvent(@"ITEM", @"%@ | id=%@ | block=%@ | host=%@ | 未识别",
                                DPOSafeString(item.title), identifier,
                                diagnostic.blockImage.lastPathComponent ?: @"-",
                                hostOwned ? @"Y" : @"N");
                }
                [keptItems addObject:item];
                continue;
            }

            DPOFeature *feature = DPOMakeFeature(item, image, section, vm, NO);
            if (feature == nil) {
                diagnostic.decision = @"无标题";
                [[DPODiagnostics shared] addEntry:diagnostic];
                if (verboseItems) {
                    DPOLogEvent(@"ITEM", @"%@ | id=%@ | owner=%@ | 无标题跳过",
                                DPOSafeString(item.title), identifier, image.lastPathComponent);
                }
                [keptItems addObject:item];
                continue;
            }
            if ([seenKeys containsObject:feature.key]) {
                diagnostic.decision = @"重复";
                [[DPODiagnostics shared] addEntry:diagnostic];
                if (verboseItems) {
                    DPOLogEvent(@"ITEM", @"%@ | id=%@ | owner=%@ | 重复收走",
                                feature.title, identifier, image.lastPathComponent);
                }
                changed = YES;   
                continue;
            }

            diagnostic.decision = @"已收纳";
            [[DPODiagnostics shared] addEntry:diagnostic];
            if (verboseItems) {
                DPOLogEvent(@"ITEM", @"%@ | id=%@ | owner=%@ | switch=%@ | 已收纳",
                            feature.title, identifier, image.lastPathComponent,
                            feature.isSwitch ? @"Y" : @"N");
            }
            if (identifier.length > 0) {
                if (DPOCollectedIdentifiers == nil) DPOCollectedIdentifiers = [NSMutableSet set];
                [DPOCollectedIdentifiers addObject:identifier];
            }
            [seenKeys addObject:feature.key];
            [collected addObject:feature];
            changed = YES;
        }

        if (!changed) {
            [keptSections addObject:section];
            continue;
        }

        if (keptItems.count == 0) {
            continue;   
        }
        if (DPOSectionReplaceItems(section, keptItems)) {
            [keptSections addObject:section];
        } else {
            [keptSections addObject:section];   
        }
    }

    DPOFeatureStore *store = [DPOFeatureStore shared];

    DPOLog(@"本轮抓到 %lu 条第三方入口，当前仓库 %lu 个插件 / %lu 项",
           (unsigned long)collected.count,
           (unsigned long)store.pluginCount,
           (unsigned long)store.featureCount);

    
    [[DPODiagnostics shared] flushToDisk];

    if (collected.count > 0) {
        DPOHarvestChangeCount += collected.count;

        
        
        NSMutableArray<DPOFeature *> *merged = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSNumber *> *indexByKey = [NSMutableDictionary dictionary];

        for (DPOPluginGroup *group in store.groups) {
            for (DPOFeature *feature in group.features) {
                if (feature.key.length == 0 || indexByKey[feature.key] != nil) continue;
                indexByKey[feature.key] = @(merged.count);
                [merged addObject:feature];
            }
        }
        for (DPOFeature *feature in collected) {
            NSNumber *index = indexByKey[feature.key];
            if (index != nil) {
                merged[index.unsignedIntegerValue] = feature;   
            } else {
                indexByKey[feature.key] = @(merged.count);
                [merged addObject:feature];
            }
        }

        NSMutableDictionary<NSString *, NSMutableArray<DPOFeature *> *> *byImage =
            [NSMutableDictionary dictionary];
        for (DPOFeature *feature in merged) {
            // 没有镜像的功能无法归组；而且 nil 不能做字典键（会直接抛异常）。
            if (feature.pluginImage.length == 0) continue;
            NSMutableArray *bucket = byImage[feature.pluginImage];
            if (bucket == nil) {
                bucket = [NSMutableArray array];
                byImage[feature.pluginImage] = bucket;
            }
            [bucket addObject:feature];
        }

        NSMutableArray<DPOPluginGroup *> *groups = [NSMutableArray arrayWithCapacity:byImage.count];
        for (NSString *image in byImage) {
            DPOPluginInfo *info = [[DPOPackageResolver shared] infoForImagePath:image];
            DPOPluginGroup *group = [[DPOPluginGroup alloc] init];
            group.imagePath = image;
            group.name = info.displayName.length > 0 ? info.displayName : DPOPluginDisplayNameFromPath(image);
            group.version = info.version;
            group.packageID = info.packageID;
            group.features = byImage[image];
            group.iconName = [self dpo_iconNameForFeatures:group.features];
            group.deepFeatureCount = [[DPOFeatureStore shared] deepFeatureCountForImage:image];

            
            
            if (group.version.length == 0) {
                for (DPOFeature *feature in group.features) {
                    if ([self dpo_looksLikeVersion:feature.subtitle]) {
                        group.version = feature.subtitle;
                        break;
                    }
                }
            }
            if (info.packageID.length == 0 && group.features.count == 1) {
                NSString *title = group.features.firstObject.title;
                if ([self dpo_isUsablePluginTitle:title]) group.name = title;
            }

            for (DPOFeature *feature in group.features) {
                feature.pluginName = group.name;
                feature.pluginVersion = group.version;
            }
            [groups addObject:group];
        }

        [groups sortUsingComparator:^NSComparisonResult(DPOPluginGroup *a, DPOPluginGroup *b) {
            return [a.name localizedStandardCompare:b.name];
        }];

        [store updateWithGroups:groups];
        DPOLogEvent(@"STORE", @"仓库合并完成：本轮 %lu 条，合计 %lu 插件 / %lu 项",
                    (unsigned long)collected.count,
                    (unsigned long)store.pluginCount,
                    (unsigned long)store.featureCount);
    }

    NSUInteger pluginCount = store.pluginCount;
    NSUInteger featureCount = store.featureCount;

    [self dpo_insertEntrySectionInto:keptSections viewModel:vm];

    DPOSessionHarvestDone = YES;
    [self dpo_rememberIdentifiers:currentIdentifiers];

    DPOLogEvent(@"HARVEST", @"结束：收走 %lu，仓库 %lu 插件 / %lu 项，扫描 %lu，section %lu/%lu",
                (unsigned long)collected.count,
                (unsigned long)pluginCount, (unsigned long)featureCount,
                (unsigned long)DPOLastScanCount,
                (unsigned long)keptSections.count, (unsigned long)sections.count);

    return [keptSections copy];
}

#pragma mark 入口行

+ (AWESettingItemModel *)dpo_makeEntryItemWithPlugins:(NSUInteger)pluginCount
                                             sections:(NSArray *)sections
                                            viewModel:(AWESettingBaseViewModel *)vm {
    Class itemClass = DPOItemClass();
    if (itemClass == Nil) return nil;

    AWESettingItemModel *item = nil;
    @try {
        item = (AWESettingItemModel *)[[itemClass alloc] init];
        item.identifier = DPOEntryIdentifier;
        item.title = DPOEntryTitle;
        item.isEnable = YES;

        if (pluginCount > 0) {
            item.detail = [NSString stringWithFormat:@"%lu 个插件", (unsigned long)pluginCount];
        } else {
            
            
            item.detail = [NSString stringWithFormat:@"v%@", DPOBuildVersion];
        }

    
    AWESettingItemModel *fallbackDonor = nil;
    for (id object in sections) {
        if (!DPOIsSection(object)) continue;
        for (id itemObject in ((AWESettingSectionModel *)object).itemArray) {
            if (!DPOIsItem(itemObject)) continue;
            AWESettingItemModel *donor = (AWESettingItemModel *)itemObject;
            if (donor.iconImageName.length == 0 && donor.svgIconImageName.length == 0) continue;

            BOOL preferred = [donor.title containsString:@"通用"] || [donor.title containsString:@"设置"];
            if (preferred) {
                item.iconImageName = donor.iconImageName;
                item.svgIconImageName = donor.svgIconImageName;
                break;
            }
            if (fallbackDonor == nil) fallbackDonor = donor;
        }
        if (item.iconImageName.length > 0 || item.svgIconImageName.length > 0) break;
    }
    if (item.iconImageName.length == 0 && item.svgIconImageName.length == 0 && fallbackDonor != nil) {
        item.iconImageName = fallbackDonor.iconImageName;
        item.svgIconImageName = fallbackDonor.svgIconImageName;
    }

        AWESettingItemModel *donor = DPOFindDonorItem(sections);
        if (donor != nil) {
            item.type = donor.type;
            item.cellType = donor.cellType;
        }
    } @catch (NSException *exception) {
        NSLog(@"[PluginNest] 构造入口行异常：%@", exception.reason);
        return nil;
    }

    __weak AWESettingBaseViewModel *weakViewModel = vm;
    
    
    item.cellTappedBlock = (void (^)(void))^id{
        DPORunOnMain(^{
            [DPOHarvester openOrganizerFromViewModel:weakViewModel];
        });
        return nil;
    };
    return item;
}


#pragma mark 页面路径（路线录制）

/// 从当前导航栈里取「插件内部页面」的标题序列。
/// 不需要额外 hook：抓行的那一刻，nav.viewControllers 已经把用户走过的层级摆在那里了。
static NSArray<NSString *> *DPOPageTrailSnapshot(void) {
    UIViewController *top = DPOTopViewController();
    NSMutableArray<NSString *> *titles = [NSMutableArray array];

    NSArray<UIViewController *> *stack = top.navigationController.viewControllers;
    if (stack.count == 0 && top != nil) stack = @[ top ];

    for (UIViewController *controller in stack) {
        NSString *title = controller.title.length > 0 ? controller.title : controller.navigationItem.title;
        if (title.length == 0) continue;
        if (titles.lastObject != nil && [titles.lastObject isEqualToString:title]) continue;
        [titles addObject:title];
    }

    // 只保留最后 3 层：底层是抖音设置页/插件根页，定位时已经在上面了，
    // 多留几层也无害（跳不过去会自动跳过）。
    while (titles.count > 3) {
        [titles removeObjectAtIndex:0];
    }
    return titles;
}

#pragma mark 看见即收录（插件自绘 TableView）

// 一次滚动里每个新 cell 都单独 merge → 单独落盘 → 单独发通知，插件页首屏
// 有几十上百行时会把主线程和磁盘一起拖住。这里攒够 24 条或 0.35s 再合并一次。
static NSMutableArray<DPOFeature *> *DPOPendingCaptures = nil;
static BOOL DPOCaptureFlushScheduled = NO;

static void DPOFlushPendingCaptures(void) {
    NSArray<DPOFeature *> *batch = nil;
    @synchronized (DPOHarvester.class) {
        if (DPOPendingCaptures.count == 0) {
            DPOCaptureFlushScheduled = NO;
            return;
        }
        batch = [DPOPendingCaptures copy];
        [DPOPendingCaptures removeAllObjects];
        DPOCaptureFlushScheduled = NO;
    }
    if (batch.count == 0) return;

    [[DPOFeatureStore shared] mergeDeepFeatures:batch];
    DPOLogEvent(@"CAPTURE", @"批量收录 %lu 条深层功能", (unsigned long)batch.count);
}

static void DPOScheduleCaptureFlush(void) {
    @synchronized (DPOHarvester.class) {
        if (DPOCaptureFlushScheduled) return;
        DPOCaptureFlushScheduled = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DPOFlushPendingCaptures();
    });
}

+ (void)captureSeenTitle:(NSString *)title ownerImage:(NSString *)image {
    if (title.length == 0 || image.length == 0) return;
    if (!DPOIsThirdPartyImage(image)) return;   // 调用方可能传错，二次兜底

    NSString *text = [title stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![self dpo_isUsablePluginTitle:text]) return;
    if ([self dpo_looksLikeVersion:text]) return;

    static NSMutableSet<NSString *> *seen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableSet set];
    });

    NSString *dedupe = [NSString stringWithFormat:@"%@|%@", image, text];
    @synchronized (seen) {
        if ([seen containsObject:dedupe]) return;
        if (seen.count >= 4000) return;      // 长时间使用的增长兜底
        [seen addObject:dedupe];
    }

    DPOFeature *feature = [[DPOFeature alloc] init];
    feature.title = text;
    feature.pluginImage = image;
    feature.pluginName = DPOPluginDisplayNameFromPath(image);
    feature.isDeep = YES;
    feature.key = [NSString stringWithFormat:@"seen|%@|%@", image, text];

    NSMutableArray<NSString *> *trail = [DPOPageTrailSnapshot() mutableCopy];
    [trail addObject:text];
    feature.locatorTrail = trail;

    [feature refreshSearchBlob];

    BOOL flushNow = NO;
    @synchronized (DPOHarvester.class) {
        if (DPOPendingCaptures == nil) DPOPendingCaptures = [NSMutableArray array];
        [DPOPendingCaptures addObject:feature];
        flushNow = (DPOPendingCaptures.count >= 24);
        if (flushNow) DPOCaptureFlushScheduled = NO;
    }
    if (flushNow) {
        DPOFlushPendingCaptures();
    } else {
        DPOScheduleCaptureFlush();
    }
}

#pragma mark 子页面：收录嵌套入口

+ (NSArray *)handleSubPageViewModel:(AWESettingBaseViewModel *)vm sections:(NSArray *)sections {
    if (vm == nil || ![sections isKindOfClass:[NSArray class]] || sections.count == 0) return sections;
    
    if (DPOClassifySettingsViewModel(vm) != DPOSettingsViewModelKindSubPage) return sections;
    
    if (DPOPageOwnedByHostSettings(vm)) return sections;

    
    
    
    static __weak AWESettingBaseViewModel *processedViewModel = nil;
    static NSArray *processedSections = nil;
    static NSTimeInterval processedAt = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (vm == processedViewModel && processedSections != nil && now - processedAt < 0.5) {
        return processedSections;
    }

    
    NSString *pageOwner = DPOActivePluginImage();
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];

    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) continue;
        NSArray *items = ((AWESettingSectionModel *)sectionObject).itemArray;
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (id itemObject in items) {
            if (!DPOIsItem(itemObject)) continue;
            NSString *image = DPOPluginImageForItem((AWESettingItemModel *)itemObject);
            if (image.length == 0) continue;
            counts[image] = @(counts[image].integerValue + 1);
        }
    }

    if (pageOwner.length == 0) {
        NSInteger best = 0;
        for (NSString *image in counts) {
            NSInteger value = counts[image].integerValue;
            if (value > best) {
                best = value;
                pageOwner = image;
            }
        }
    }
    if (pageOwner.length == 0) return sections;

    NSMutableArray<DPOFeature *> *nested = [NSMutableArray array];

    // 本页「自己」的功能 → 深层搜索索引（跨启动持久化）。
    // 下次没打开这个页面也能搜到，点结果时再按 locator 定位。
    NSMutableArray<DPOFeature *> *ownDeep = [NSMutableArray array];
    NSString *pageClassName = NSStringFromClass([vm class]);
    NSInteger itemCursor = 0;

    for (id sectionObject in sections) {
        if (!DPOIsSection(sectionObject)) continue;

        AWESettingSectionModel *section = (AWESettingSectionModel *)sectionObject;
        NSArray *items = section.itemArray;
        if (![items isKindOfClass:[NSArray class]] || items.count == 0) continue;

        for (id itemObject in items) {
            if (!DPOIsItem(itemObject)) continue;

            AWESettingItemModel *item = (AWESettingItemModel *)itemObject;
            NSInteger cursor = itemCursor++;
            NSString *identifier = DPOSafeString(item.identifier);
            if ([identifier hasPrefix:DPOEntryIdentifier]) continue;

            NSString *image = DPOPluginImageForItem(item);
            if (image.length == 0) continue;

            if ([image isEqualToString:pageOwner]) {
                if (ownDeep.count >= 150) continue;

                NSString *rawTitle = DPOSafeString(item.title);
                if (rawTitle.length == 0) continue;
                if (![self dpo_isUsablePluginTitle:rawTitle]) continue;
                if ([self dpo_looksLikeVersion:rawTitle]) continue;

                DPOFeature *deep = DPOMakeFeature(item, image, section, nil, YES);
                if (deep == nil) continue;

                deep.locatorPage = pageClassName;
                deep.locatorIndex = cursor;
                if (deep.pluginName.length == 0) {
                    deep.pluginName = DPOPluginDisplayNameFromPath(image);
                }
                NSString *sectionTitle = DPOSafeString(section.sectionHeaderTitle);
                if (sectionTitle.length > 0) deep.sectionTitle = sectionTitle;

                // 页面路径 + 目标标题 = 可重放的路线：定位时从插件根页开始，
                // 按页面标题一格一格点下去，二级页、三级页都能走到。
                NSMutableArray<NSString *> *trail = [DPOPageTrailSnapshot() mutableCopy];
                [trail addObject:deep.title];
                deep.locatorTrail = trail;
                [ownDeep addObject:deep];
                continue;
            }

            DPOFeature *feature = DPOMakeFeature(item, image, section, vm, NO);
            if (feature == nil) continue;

            [nested addObject:feature];
        }
    }

    if (ownDeep.count > 0) [[DPOFeatureStore shared] mergeDeepFeatures:ownDeep];
    if (nested.count > 0) [self mergeNestedFeatures:nested];

    
    static NSString *lastPageOwner = nil;
    static NSUInteger lastNestedCount = NSUIntegerMax;
    static NSTimeInterval lastPageLogAt = 0;
    NSTimeInterval pageStamp = [NSDate date].timeIntervalSince1970;
    BOOL sameOwner = (lastPageOwner != nil && [lastPageOwner isEqualToString:pageOwner]);
    if (!sameOwner || nested.count != lastNestedCount || pageStamp - lastPageLogAt > 3.0) {
        lastPageOwner = [pageOwner copy];
        lastNestedCount = nested.count;
        lastPageLogAt = pageStamp;
        DPOLogEvent(@"PAGE", @"%@ owner=%@ sections=%lu 收录=%lu 深索引=%lu",
                    NSStringFromClass([vm class]), pageOwner.lastPathComponent,
                    (unsigned long)sections.count, (unsigned long)nested.count,
                    (unsigned long)ownDeep.count);
    }

    processedViewModel = vm;
    processedSections = sections;
    processedAt = now;
    return sections;
}

+ (NSString *)dpo_iconNameForFeatures:(NSArray<DPOFeature *> *)features {
    for (DPOFeature *feature in features) {
        if (feature.item.iconImageName.length > 0) return feature.item.iconImageName;
        if (feature.item.svgIconImageName.length > 0) return feature.item.svgIconImageName;
    }
    return nil;
}

+ (void)mergeNestedFeatures:(NSArray<DPOFeature *> *)features {
    if (features.count == 0) return;

    DPOFeatureStore *store = [DPOFeatureStore shared];
    NSUInteger beforeFeatureCount = store.featureCount;
    NSMutableArray<DPOFeature *> *merged = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *indexByKey = [NSMutableDictionary dictionary];

    for (DPOPluginGroup *group in store.groups) {
        for (DPOFeature *feature in group.features) {
            if (feature.key.length == 0 || indexByKey[feature.key] != nil) continue;
            indexByKey[feature.key] = @(merged.count);
            [merged addObject:feature];
        }
    }
    for (DPOFeature *feature in features) {
        NSNumber *index = indexByKey[feature.key];
        if (index != nil) {
            merged[index.unsignedIntegerValue] = feature;
        } else {
            indexByKey[feature.key] = @(merged.count);
            [merged addObject:feature];
        }
    }

    NSMutableDictionary<NSString *, NSMutableArray<DPOFeature *> *> *byImage = [NSMutableDictionary dictionary];
    for (DPOFeature *feature in merged) {
        
        NSString *image = feature.pluginImage;
        if (image.length == 0) continue;
        NSMutableArray *bucket = byImage[image];
        if (bucket == nil) {
            bucket = [NSMutableArray array];
            byImage[image] = bucket;
        }
        [bucket addObject:feature];
    }

    NSMutableArray<DPOPluginGroup *> *groups = [NSMutableArray arrayWithCapacity:byImage.count];
    for (NSString *image in byImage) {
        DPOPluginInfo *info = [[DPOPackageResolver shared] infoForImagePath:image];
        DPOPluginGroup *group = [[DPOPluginGroup alloc] init];
        group.imagePath = image;
        group.name = info.displayName.length > 0 ? info.displayName : DPOPluginDisplayNameFromPath(image);
        group.version = info.version;
        group.packageID = info.packageID;
        group.features = byImage[image];
        group.iconName = [self dpo_iconNameForFeatures:group.features];
        group.deepFeatureCount = [[DPOFeatureStore shared] deepFeatureCountForImage:image];

        if (group.version.length == 0) {
            for (DPOFeature *feature in group.features) {
                if ([self dpo_looksLikeVersion:feature.subtitle]) {
                    group.version = feature.subtitle;
                    break;
                }
            }
        }
        if (info.packageID.length == 0 && group.features.count == 1) {
            NSString *title = group.features.firstObject.title;
            if ([self dpo_isUsablePluginTitle:title]) group.name = title;
        }

        for (DPOFeature *feature in group.features) {
            feature.pluginName = group.name;
            feature.pluginVersion = group.version;
        }
        [groups addObject:group];
    }

    [groups sortUsingComparator:^NSComparisonResult(DPOPluginGroup *a, DPOPluginGroup *b) {
        return [a.name localizedStandardCompare:b.name];
    }];

    [store updateWithGroups:groups];

    
    
    

    if (store.featureCount != beforeFeatureCount) {
        DPOLogEvent(@"SUBPAGE", @"仓库合并：%lu 个插件 / %lu 项",
                    (unsigned long)store.pluginCount, (unsigned long)store.featureCount);
    }
}

#pragma mark 直接打开插件设置页

static BOOL DPOClassIsViewController(Class cls) {
    Class cursor = cls;
    NSUInteger guard = 0;
    while (cursor != Nil && guard < 32) {
        if (cursor == [UIViewController class]) return YES;
        cursor = class_getSuperclass(cursor);
        guard += 1;
    }
    return NO;
}

+ (Class)dpo_settingsControllerClassForImage:(NSString *)image {
    if (image.length == 0) return Nil;

    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(image.fileSystemRepresentation, &count);
    if (names == NULL) return Nil;
    if (count == 0) {
        free(names);
        return Nil;
    }

    Class best = Nil;
    NSInteger bestScore = 0;

    for (unsigned int index = 0; index < count; index++) {
        const char *raw = names[index];
        if (raw == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:raw];
        if (name.length == 0) continue;
        if ([name hasPrefix:@"DPO"] || [name hasPrefix:@"_"] || [name hasPrefix:@"NS"]) continue;
        if ([name containsString:@"Cell"] || [name containsString:@"Window"] ||
            [name containsString:@"Alert"] || [name containsString:@"Navigation"]) continue;

        Class cls = objc_getClass(raw);
        if (cls == Nil || !DPOClassIsViewController(cls)) continue;

        NSInteger score = 0;
        if ([name containsString:@"Settings"]) score += 10;
        else if ([name containsString:@"Setting"]) score += 8;
        if ([name containsString:@"Preferences"]) score += 7;
        if ([name containsString:@"Config"]) score += 5;
        if ([name containsString:@"Panel"]) score += 4;
        if ([name containsString:@"Helper"]) score += 2;
        if ([name containsString:@"Main"]) score += 2;
        if ([name hasSuffix:@"ViewController"]) score += 2;

        NSArray<NSString *> *penalties = @[
            @"Friend", @"Detail", @"Editor", @"Log", @"Picker", @"Preview",
            @"Message", @"Feed", @"Contact", @"History", @"Debug", @"Test"
        ];
        for (NSString *keyword in penalties) {
            if ([name containsString:keyword]) score -= 7;
        }

        if (score > bestScore) {
            bestScore = score;
            best = cls;
        }
    }

    free(names);
    if (bestScore < 4) return Nil;
    return best;
}

+ (BOOL)openPluginSettingsPageForImage:(NSString *)image from:(UIViewController *)host {
    if (image.length == 0) return NO;

    UIViewController *presenter = host ?: DPOTopViewController();
    if (presenter == nil) return NO;

    // 已知导出 C 入口：DYKiller
    if ([image containsString:@"DYKiller"]) {
        void (*openMain)(UIViewController *) =
            (void (*)(UIViewController *))dlsym(RTLD_DEFAULT, "DKSettingsOpenMain");
        if (openMain == NULL) {
            void *handle = dlopen(image.fileSystemRepresentation, RTLD_LAZY);
            if (handle != NULL) {
                openMain = (void (*)(UIViewController *))dlsym(handle, "DKSettingsOpenMain");
            }
        }
        if (openMain != NULL) {
            DPOBeginActivation(image);
            @try {
                openMain(presenter);
                DPOLogEvent(@"OPEN", @"用 DKSettingsOpenMain 直开 DYKiller");
                return YES;
            } @catch (__unused NSException *exception) {
            }
        }
    }

    Class controllerClass = [self dpo_settingsControllerClassForImage:image];
    if (controllerClass == Nil) return NO;

    UIViewController *page = nil;
    @try {
        page = [[controllerClass alloc] init];
    } @catch (NSException *exception) {
        DPOLogEvent(@"OPEN", @"创建 %@ 失败：%@", NSStringFromClass(controllerClass), exception.reason);
        return NO;
    }
    if (page == nil) return NO;

    // 先强制加载一次 view。插件页的 viewDidLoad 很可能读过私有数据/注册通知，
    // 异常要挡在 push 之前，否则会把整个设置页栈带崩。
    @try {
        (void)page.view;
    } @catch (NSException *exception) {
        DPOLogEvent(@"OPEN", @"%@ 预加载失败：%@",
                    NSStringFromClass(controllerClass), exception.reason);
        return NO;
    }

    DPOBeginActivation(image);
    DPOLogEvent(@"OPEN", @"直开插件页：%@（%@）",
                NSStringFromClass(controllerClass), image.lastPathComponent);

    DPORunOnMain(^{
        @try {
            UINavigationController *navigation = presenter.navigationController;
            if (navigation != nil && navigation.topViewController == presenter) {
                [navigation pushViewController:page animated:YES];
            } else {
                UINavigationController *wrapper =
                    [[UINavigationController alloc] initWithRootViewController:page];
                wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
                [presenter presentViewController:wrapper animated:YES completion:nil];
            }
        } @catch (NSException *exception) {
            DPOLogEvent(@"OPEN", @"打开插件页异常：%@", exception.reason);
        }
    });
    return YES;
}

#pragma mark 定位（搜索命中后自动翻到那一行）

// 激活链：用户从设置页点到第 N 层时，按下的每一级标题。深层索引把这条链一起存下来，
// 定位时就能一级一级重放，而不是瞎翻。
static NSMutableArray<NSString *> *DPOActivationTrail(void) {
    static NSMutableArray<NSString *> *trail = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        trail = [NSMutableArray array];
    });
    return trail;
}

static void DPOActivationTrailPush(NSString *title) {
    if (title.length == 0) return;
    NSMutableArray<NSString *> *trail = DPOActivationTrail();
    @synchronized (trail) {
        if (trail.count >= 3) [trail removeObjectAtIndex:0];
        // 同一层反复点同一项时不重复记
        if (trail.lastObject != nil && [trail.lastObject isEqualToString:title]) return;
        [trail addObject:title];
    }
}

static void DPOActivationTrailReset(void) {
    NSMutableArray<NSString *> *trail = DPOActivationTrail();
    @synchronized (trail) {
        [trail removeAllObjects];
    }
}

static NSArray<NSString *> *DPOActivationTrailSnapshot(void) {
    NSMutableArray<NSString *> *trail = DPOActivationTrail();
    @synchronized (trail) {
        return [trail copy];
    }
}

static UITableView *DPOLocateTableView(void) {
    return DPOTopmostTableView();
}

static NSString *DPOTrimmedTitle(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return @"";
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// 2 = 完全一致；1 = 长标题互相包含；0 = 不匹配。
/// 两个字的标题只认完全一致：旧实现用 contains 做双向匹配，「设置」会命中
/// 「设置密码」/「设置通知」，「通用」会命中「通用设置」，定位时点错行比点不到更糟。
static NSInteger DPOTitleMatchScore(NSString *a, NSString *b) {
    NSString *x = DPOTrimmedTitle(a);
    NSString *y = DPOTrimmedTitle(b);
    if (x.length == 0 || y.length == 0) return 0;
    if ([x isEqualToString:y]) return 2;
    // 插件常给标题加后缀（「移除长视频」vs「移除长视频开关」）；4 个字以下不做模糊。
    if (x.length >= 4 && [y containsString:x]) return 1;
    if (y.length >= 4 && [x containsString:y]) return 1;
    return 0;
}

static BOOL DPOTitleMatches(NSString *a, NSString *b) {
    return DPOTitleMatchScore(a, b) > 0;
}

static NSInteger DPODataSourceSections(id<UITableViewDataSource> source, UITableView *tableView) {
    if (source == nil) return 0;
    @try {
        if ([source respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
            return [source numberOfSectionsInTableView:tableView];
        }
        return 1;
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static NSInteger DPODataSourceRows(id<UITableViewDataSource> source, UITableView *tableView, NSInteger section) {
    if (source == nil || section < 0) return 0;
    @try {
        return [source tableView:tableView numberOfRowsInSection:section];
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

/// 在表格里找标题匹配的行。总行数超过 400 的一律不扫（多半不是设置页）。
/// exactOnly = YES 时只接受完全一致，用于「中间页下钻」阶段，避免误点。
static NSIndexPath *DPOFindRowWithTitle(UITableView *tableView, NSString *title, BOOL exactOnly) {
    if (tableView == nil || title.length == 0) return nil;
    id<UITableViewDataSource> source = tableView.dataSource;
    if (source == nil) return nil;
    if (![source respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) return nil;

    // 这几句也是插件的 dataSource 在跑，必须兜异常：旧实现把总行数统计放在
    // @try 外面，dataSource 抛异常时异常会直接冲到 runloop，把抖音带走。
    NSInteger sections = DPODataSourceSections(source, tableView);
    if (sections <= 0 || sections > 64) return nil;

    NSInteger total = 0;
    for (NSInteger section = 0; section < sections; section++) {
        total += DPODataSourceRows(source, tableView, section);
        if (total > 400) return nil;
    }
    if (total <= 0) return nil;

    NSIndexPath *best = nil;
    NSInteger bestScore = 0;
    NSMutableArray<NSString *> *samples = [NSMutableArray array];

    @try {
        for (NSInteger section = 0; section < sections; section++) {
            NSInteger rows = DPODataSourceRows(source, tableView, section);
            for (NSInteger row = 0; row < rows; row++) {
                @autoreleasepool {
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
                    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                    if (cell == nil) {
                        cell = [source tableView:tableView cellForRowAtIndexPath:indexPath];
                    }
                    NSString *cellTitle = DPOCellTitle(cell);
                    NSInteger score = DPOTitleMatchScore(cellTitle, title);
                    if (score == 2) return indexPath;
                    if (!exactOnly && score > bestScore) {
                        bestScore = score;
                        best = indexPath;
                    }
                    if (cellTitle.length > 0 && samples.count < 8) [samples addObject:cellTitle];
                }
            }
        }
    } @catch (__unused NSException *exception) {
        // 插件 dataSource 在扫到一半时抛异常：最好的那个可能来自更早的错误行，
        // 直接放弃比闪错行安全。
        return nil;
    }

    if (best == nil) {
        DPOLogEvent(@"LOCATE", @"扫了 %ld 行没找到「%@」，样例=%@",
                    (long)total, title, [samples componentsJoinedByString:@" / "]);
    }
    return best;
}

static BOOL DPOIndexPathIsValid(UITableView *tableView, NSIndexPath *indexPath) {
    if (tableView == nil || indexPath == nil) return NO;
    id<UITableViewDataSource> source = tableView.dataSource;
    if (source == nil) return NO;

    NSInteger sections = DPODataSourceSections(source, tableView);
    if (indexPath.section < 0 || indexPath.section >= sections) return NO;

    NSInteger rows = DPODataSourceRows(source, tableView, indexPath.section);
    return indexPath.row >= 0 && indexPath.row < rows;
}

static void DPOFlashRow(UITableView *tableView, NSIndexPath *indexPath) {
    if (!DPOIndexPathIsValid(tableView, indexPath)) return;

    @try {
        [tableView scrollToRowAtIndexPath:indexPath
                           atScrollPosition:UITableViewScrollPositionMiddle
                                   animated:YES];
    } @catch (__unused NSException *exception) {
        // 扫表和滚动之间插件 reload 了数据源：这一行已经不存在，静默放弃。
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 延迟回来时 indexPath 可能已经失效，必须再校验一次。
        if (!DPOIndexPathIsValid(tableView, indexPath)) return;
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell == nil) return;

        UIColor *previous = cell.contentView.backgroundColor;
        [UIView animateWithDuration:0.18 animations:^{
            cell.contentView.backgroundColor = [DPOColorAccent() colorWithAlphaComponent:0.22];
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.55
                                  delay:0.75
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                                 cell.contentView.backgroundColor = previous;
                             }
                             completion:nil];
        }];
    });
}

/// 走 delegate 的 didSelect；只用于「中间页下钻」，不用于最终目标。
static BOOL DPOTapRow(UITableView *tableView, NSIndexPath *indexPath) {
    if (!DPOIndexPathIsValid(tableView, indexPath)) return NO;
    id<UITableViewDelegate> delegate = tableView.delegate;
    if (delegate == nil ||
        ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;

    @try {
        [tableView selectRowAtIndexPath:indexPath
                               animated:NO
                         scrollPosition:UITableViewScrollPositionNone];
        [delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

// 一次定位会话
static DPOFeature *DPOLocateTarget = nil;
static NSArray<NSString *> *DPOLocatePath = nil;
static NSUInteger DPOLocatePathIndex = 0;
static NSInteger DPOLocateAttempt = 0;
static NSInteger DPOLocateLevelMiss = 0;
static BOOL DPOLocateSearchFieldTried = NO;
static NSString *DPOLocateHostImage = nil;
static NSInteger DPOLocateSession = 0;

static void DPOLocateTick(void);

static void DPOLocateReset(void) {
    DPOLocateTarget = nil;
    DPOLocatePath = nil;
    DPOLocatePathIndex = 0;
    DPOLocateAttempt = 0;
    DPOLocateLevelMiss = 0;
    DPOLocateSearchFieldTried = NO;
    DPOLocateHostImage = nil;
}

static void DPOLocateFail(NSString *reason) {
    DPOLocateReset();
    DPOLocateSession += 1;       // 让已经排队的 tick 全部失效
    if (reason.length > 0) {
        DPOLogEvent(@"LOCATE", @"失败：%@", reason);
        [DPOToast show:reason];
    }
}

static void DPOLocateFinish(void) {
    DPOLocateReset();
    DPOLocateSession += 1;
}

static void DPOLocateSchedule(void) {
    // 渐进间隔：前几次等转场，后面固定 0.9s 等慢插件
    static const double kIntervals[] = { 0.18, 0.24, 0.32, 0.42, 0.55, 0.70, 0.85 };
    double delay = DPOLocateAttempt < 7 ? kIntervals[DPOLocateAttempt] : 0.9;
    NSInteger session = DPOLocateSession;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (session != DPOLocateSession) return;
        DPOLocateTick();
    });
}

#pragma mark 模型层定位（优先走 sectionDataArray，扫表只做兜底）

static NSArray *DPOSettingsSectionArray(UIViewController *controller) {
    if (controller == nil) return nil;
    id viewModel = nil;
    @try {
        viewModel = [controller valueForKey:@"viewModel"];
    } @catch (__unused NSException *exception) {
        viewModel = nil;
    }
    if (viewModel == nil) return nil;
    @try {
        id sections = [viewModel valueForKey:@"sectionDataArray"];
        return [sections isKindOfClass:[NSArray class]] ? sections : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *DPOItemStringValue(id item, NSString *key) {
    @try {
        id value = [item valueForKey:key];
        return [value isKindOfClass:[NSString class]] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// 在 sectionDataArray 里按标题找行。先按「分组 + 标题」双键，再退化到只比标题。
/// 完全一致优先；都没有时才用长标题互相包含的模糊结果。
static NSDictionary *DPOFindItemInSections(NSArray *sections,
                                           NSString *sectionTitle,
                                           NSString *title,
                                           BOOL exactOnly) {
    if (![sections isKindOfClass:[NSArray class]] || sections.count == 0 || title.length == 0) return nil;

    NSDictionary *best = nil;
    NSInteger bestScore = 0;

    for (NSInteger pass = 0; pass < 2; pass++) {
        for (NSUInteger sectionIndex = 0; sectionIndex < sections.count; sectionIndex++) {
            id section = sections[sectionIndex];
            NSString *header = DPOItemStringValue(section, @"sectionHeaderTitle");
            if (pass == 0 && sectionTitle.length > 0 && ![header isEqualToString:sectionTitle]) continue;

            NSArray *items = nil;
            @try {
                id value = [section valueForKey:@"itemArray"];
                items = [value isKindOfClass:[NSArray class]] ? value : nil;
            } @catch (__unused NSException *exception) {
                items = nil;
            }

            for (NSUInteger rowIndex = 0; rowIndex < items.count; rowIndex++) {
                id item = items[rowIndex];
                NSInteger score = DPOTitleMatchScore(DPOItemStringValue(item, @"title"), title);
                if (score == 2) {
                    return @{ @"section": @(sectionIndex),
                              @"row": @(rowIndex),
                              @"item": item,
                              @"header": header ?: @"" };
                }
                if (!exactOnly && score > bestScore) {
                    bestScore = score;
                    best = @{ @"section": @(sectionIndex),
                              @"row": @(rowIndex),
                              @"item": item,
                              @"header": header ?: @"" };
                }
            }
        }
    }
    return best;
}

/// 抖音设置框架里「会 push 下一页」的行：cellType 26。
/// 拿不到 cellType 时按「不是导航行」处理：旧实现默认 YES，会把开关行/按钮行
/// 当成页面点进去，轻则误触，重则把子页面的 block 反复执行。
static BOOL DPOItemIsNavigationRow(id item) {
    if (item == nil) return NO;
    @try {
        id value = [item valueForKey:@"cellType"];
        if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value integerValue] == 26;
    } @catch (__unused NSException *exception) {
    }
    return NO;
}

/// 直接执行这一行自己的跳转 block——比在表格上模拟 didSelect 稳得多。
static BOOL DPOInvokeItemNavigation(id item) {
    if (item == nil) return NO;
    id block = nil;
    @try {
        block = [item valueForKey:@"cellTappedBlock"];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (block == nil || ![NSStringFromClass([block class]) containsString:@"Block"]) return NO;
    @try {
        ((void (^)(void))block)();
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

/// 插件自带搜索框：定位不到时把标题打进去，行数立刻收敛。
static UITextField *DPOFindPluginSearchField(UIView *view, NSInteger depth) {
    if (view == nil || depth < 0 || view.hidden || view.alpha < 0.01) return nil;
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        NSString *label = [field.accessibilityLabel lowercaseString] ?: @"";
        NSString *placeholder = [field.placeholder lowercaseString] ?: @"";
        if ([label containsString:@"搜索"] || [placeholder containsString:@"搜索"] ||
            [label containsString:@"search"] || [placeholder containsString:@"search"]) {
            return field;
        }
    }
    for (UIView *subview in view.subviews) {
        UITextField *found = DPOFindPluginSearchField(subview, depth - 1);
        if (found != nil) return found;
    }
    return nil;
}

static BOOL DPOTypeIntoSettingsSearchField(UIViewController *controller, NSString *title) {
    if (controller == nil || title.length == 0) return NO;
    @try {
        UITextField *field = DPOFindPluginSearchField(controller.viewIfLoaded, 12);
        if (field == nil || field.window == nil) return NO;
        if (![field.text isEqualToString:title]) {
            field.text = title;
            [field sendActionsForControlEvents:UIControlEventEditingChanged];
        }
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void DPOLocateTick(void) {
    if (DPOLocateTarget == nil || DPOLocatePath.count == 0) return;

    DPOLocateAttempt += 1;
    if (DPOLocateAttempt > 14) {
        DPOLocateFail([NSString stringWithFormat:@"已打开插件页，未能定位到「%@」", DPOLocatePath.lastObject]);
        return;
    }

    // 整段兜住：dataSource / delegate / 插件的跳转 block 都是别人的代码，
    // 任何异常都不能从 dispatch_after 的 block 里冲回 runloop（那是直接闪退）。
    @try {
        // 插件页还没起来（还停在搜索页/收纳页）就什么都别点：
        // 否则会把自己表格里的结果行当成"下一级入口"点下去，形成自我递归。
        UIViewController *top = DPOTopViewController();
        if (top == nil || [NSStringFromClass([top class]) hasPrefix:@"DPO"]) {
            DPOLocateSchedule();
            return;
        }

        NSString *target = DPOLocatePath.lastObject;
        UITableView *tableView = DPOLocateTableView();
        NSArray *sections = DPOSettingsSectionArray(top);
        BOOL lastPage = (DPOLocatePathIndex + 1 >= DPOLocatePath.count);

        // ① 最后一段：允许模糊匹配，命中后只高亮，绝不再点目标行。
        //    旧实现只要命中行是 cellType 26 就执行它的 block，遇到「设置」这种
        //    既是页标题又是行标题的目标会一路往下一页钻，14 次后弹失败。
        if (lastPage) {
            NSDictionary *hit = DPOFindItemInSections(sections,
                                                       DPOLocateTarget.sectionTitle,
                                                       target,
                                                       NO);
            if (hit != nil) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[hit[@"row"] integerValue]
                                                            inSection:[hit[@"section"] integerValue]];
                DPOLogEvent(@"LOCATE", @"命中（模型）：%@ %@", target, indexPath);
                DPOFlashRow(tableView ?: DPOLocateTableView(), indexPath);
                DPOLocateFinish();
                return;
            }

            NSIndexPath *rowHit = DPOFindRowWithTitle(tableView, target, NO);
            if (rowHit != nil) {
                DPOLogEvent(@"LOCATE", @"命中（扫表）：%@ %@", target, rowHit);
                DPOFlashRow(tableView, rowHit);
                DPOLocateFinish();
                return;
            }
        } else {
            // 当前页可能已经是目标页（trail 前几段是父页），精确命中就直接收工。
            NSDictionary *hit = DPOFindItemInSections(sections,
                                                       DPOLocateTarget.sectionTitle,
                                                       target,
                                                       YES);
            if (hit != nil) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[hit[@"row"] integerValue]
                                                            inSection:[hit[@"section"] integerValue]];
                DPOLogEvent(@"LOCATE", @"提前命中（模型）：%@ %@", target, indexPath);
                DPOFlashRow(tableView ?: DPOLocateTableView(), indexPath);
                DPOLocateFinish();
                return;
            }
        }

        // ② 中间页：按 trail 的下一段标题下钻。matcher 已经保证 4 字以下只认
        //    完全一致，所以这里允许长标题模糊匹配，保留「隐私设置」这类缩写路径。
        if (!lastPage) {
            NSString *next = DPOLocatePath[DPOLocatePathIndex];
            BOOL advanced = NO;

            NSDictionary *step = DPOFindItemInSections(sections, nil, next, NO);
            if (step != nil && DPOInvokeItemNavigation(step[@"item"])) {
                advanced = YES;
            } else if (tableView != nil) {
                NSIndexPath *stepRow = DPOFindRowWithTitle(tableView, next, NO);
                if (stepRow != nil) advanced = DPOTapRow(tableView, stepRow);
            }

            if (advanced) {
                DPOLogEvent(@"LOCATE", @"下钻一级：%@", next);
                DPOLocateLevelMiss = 0;
                DPOLocatePathIndex += 1;
                DPOLocateSchedule();
                return;
            }

            DPOLocateLevelMiss += 1;
            if (DPOLocateLevelMiss >= 3) {
                DPOLogEvent(@"LOCATE", @"跳过一级：%@", next);
                DPOLocateLevelMiss = 0;
                DPOLocatePathIndex += 1;
            }
            DPOLocateSchedule();
            return;
        }

        // ③ 最后一页还没找到：试一次插件自带搜索框，然后继续等页面刷新。
        if (DPOLocateAttempt == 5 && !DPOLocateSearchFieldTried) {
            DPOLocateSearchFieldTried = YES;
            if (DPOTypeIntoSettingsSearchField(top, target)) {
                DPOLogEvent(@"LOCATE", @"已把「%@」打进插件搜索框", target);
            }
        }

        DPOLocateSchedule();
    } @catch (NSException *exception) {
        DPOLocateFail([NSString stringWithFormat:@"定位异常：%@",
                       exception.reason ?: exception.name ?: @"未知"]);
    }
}

+ (void)locateFeature:(DPOFeature *)feature from:(UIViewController *)host {
    if (feature == nil || feature.title.length == 0) return;

    if (!feature.isDeep) {
        [self activateFeature:feature from:host];
        return;
    }

    NSArray<NSString *> *trail = feature.locatorTrail.count > 0
                                     ? feature.locatorTrail
                                     : @[ feature.title ];

    NSMutableArray<NSString *> *path = [NSMutableArray array];
    for (id step in trail) {
        if ([step isKindOfClass:[NSString class]] && [step length] > 0) {
            [path addObject:step];
        }
    }
    if (path.count == 0) [path addObject:feature.title];
    if (![[path lastObject] isEqualToString:feature.title]) [path addObject:feature.title];

    // 去掉明显不是「行」的前缀：设置页标题 / 入口行标题 / 插件名。
    // 它们在导航栈里，但不会以行标题的形式出现在插件页上；留着只会让
    // tick 先白点三次再跳过。
    while (path.count > 1) {
        NSString *first = path.firstObject;
        BOOL noise = [first isEqualToString:@"设置"] ||
                     [first isEqualToString:DPOEntryTitle] ||
                     (feature.pluginName.length > 0 && [first isEqualToString:feature.pluginName]);
        if (!noise) break;
        [path removeObjectAtIndex:0];
    }

    DPOLocateSession += 1;       // 取消上一次尚未跑完的定位
    DPOLocateTarget = feature;
    DPOLocatePath = [path copy];
    DPOLocatePathIndex = 0;
    DPOLocateAttempt = 0;
    DPOLocateLevelMiss = 0;
    DPOLocateSearchFieldTried = NO;
    DPOLocateHostImage = feature.pluginImage;

    DPOLogEvent(@"LOCATE", @"开始定位：%@ 路径=%@", feature.title, path);

    [self activateFeature:feature from:host];
    DPOLocateSchedule();
}

#pragma mark 打开收纳页

+ (void)openOrganizerFromViewModel:(AWESettingBaseViewModel *)vm {
    DPORunOnMain(^{
        
        
        static NSTimeInterval lastOpenAt = 0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - lastOpenAt < 1.0) return;

        UIViewController *top = DPOTopViewController();
        if (top == nil) return;
        if ([top isKindOfClass:[DPOOrganizerViewController class]]) return;

        for (UIViewController *controller in top.navigationController.viewControllers) {
            if ([controller isKindOfClass:[DPOOrganizerViewController class]]) return;
        }
        lastOpenAt = now;

        DPOLogEvent(@"OPEN", @"打开收纳页：top=%@", NSStringFromClass([top class]));

        
        
        DPOOrganizerViewController *organizer =
            [[DPOOrganizerViewController alloc] initWithViewModel:vm];
        organizer.hidesBottomBarWhenPushed = YES;

        UINavigationController *nav = top.navigationController;
        if (nav != nil && nav.viewControllers.count > 0) {
            [nav pushViewController:organizer animated:YES];
        } else {
            UINavigationController *wrapper =
                [[UINavigationController alloc] initWithRootViewController:organizer];
            wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
            [top presentViewController:wrapper animated:YES completion:nil];
        }
    });
}

#pragma mark 执行功能

+ (void)activateFeature:(DPOFeature *)feature from:(UIViewController *)host {
    if (feature == nil) return;

    
    DPOFeature *fresh = [[DPOFeatureStore shared] featureForKey:feature.key];
    if (fresh != nil) feature = fresh;

    __block DPOFeature *activeFeature = feature;
    DPORunOnMain(^{
        DPOLogEvent(@"ACT", @"点击：%@ | id=%@ | switch=%@ | deep=%@ | host=%@",
                    activeFeature.title, activeFeature.identifier,
                    activeFeature.isSwitch ? @"Y" : @"N",
                    activeFeature.isDeep ? @"Y" : @"N",
                    host != nil ? NSStringFromClass([host class]) : @"(nil)");

        if (activeFeature.isDeep) {
            [self dpo_openPluginPageForDeepFeature:activeFeature from:host];
            return;
        }
        // 记录「点到这一层」的标题，深层索引据此生成可重放的路径。
        if (!activeFeature.isSwitch) DPOActivationTrailPush(activeFeature.title);
        if (activeFeature.isSwitch) {
            [self toggleFeature:activeFeature];
            return;
        }

        AWESettingItemModel *item = activeFeature.item;
        void (^block)(void) = item.cellTappedBlock;
        if (block == nil) {
            [DPOToast show:@"这个功能没有可打开的页面"];
            return;
        }

        
        
        
        
        UIViewController *presenter = host ?: DPOTopViewController();

        
        
        
        
        
        
        
        
        
        
        
        AWESettingBaseViewModel *liveViewModel = nil;
        UIViewController *settingsController = nil;
        UINavigationController *navStack = presenter.navigationController;
        if ([presenter isKindOfClass:[DPOOrganizerViewController class]]) {
            if (navStack.viewControllers.count > 1) {
                
                settingsController = navStack.viewControllers[navStack.viewControllers.count - 2];
            } else if (presenter.presentingViewController != nil) {
                
                settingsController = presenter.presentingViewController;
            }
        }
        if (settingsController != nil) {
            
            NSArray<UIViewController *> *candidates = @[ settingsController ];
            if ([settingsController isKindOfClass:[UINavigationController class]]) {
                candidates = [(UINavigationController *)settingsController viewControllers];
            }
            for (UIViewController *candidate in candidates) {
                if ([candidate isKindOfClass:[DPOOrganizerViewController class]]) continue;
                @try {
                    id viewModel = [candidate valueForKey:@"viewModel"];
                    
                    Class vmClass = objc_getClass("AWESettingBaseViewModel");
                    if (vmClass != Nil && [viewModel isKindOfClass:vmClass]) {
                        liveViewModel = viewModel;
                        break;
                    }
                } @catch (__unused NSException *exception) {
                    continue;
                }
            }
        }
        if (liveViewModel != nil) {
            @try {
                (void)[liveViewModel sectionDataArray];
            } @catch (__unused NSException *exception) {
            }
            DPOFeature *refreshed = [[DPOFeatureStore shared] featureForKey:activeFeature.key];
            if (refreshed != nil) activeFeature = refreshed;
        }

        
        
        if (DPOIsQuarantined(activeFeature.key)) {
            UIViewController *alertHost = presenter ?: DPOTopViewController();
            if (alertHost == nil) return;
            
            if (alertHost.presentedViewController != nil) return;

            NSString *title = activeFeature.title.length > 0 ? activeFeature.title : @"这个插件";
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"已跳过这个插件"
                                                    message:[NSString stringWithFormat:
                                        @"上次打开「%@」时抖音退出了，可能是插件自身的 bug。仍然要尝试吗？", title]
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"算了"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            Class harvesterClass = self;   
            [alert addAction:[UIAlertAction actionWithTitle:@"仍要打开"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
                DPOSetQuarantined(activeFeature.key, NO);
                [harvesterClass activateFeature:activeFeature from:alertHost];
            }]];
            DPOLogEvent(@"GUARD", @"拦截已隔离插件：%@", activeFeature.title);
            
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (alertHost.presentedViewController != nil) return;
                [alertHost presentViewController:alert animated:YES completion:nil];
            });
            return;
        }

        
        
        
        
        
        
        NSString *pluginImageName = activeFeature.pluginImage.lastPathComponent ?: @"";
        if ([pluginImageName containsString:@"DYKiller"] && presenter != nil) {
            void (*dkOpenMain)(UIViewController *) =
                (void (*)(UIViewController *))dlsym(RTLD_DEFAULT, "DKSettingsOpenMain");
            if (dkOpenMain == NULL) {
                
                const char *path = activeFeature.pluginImage.fileSystemRepresentation;
                void *handle = path != NULL ? dlopen(path, RTLD_LAZY) : NULL;
                if (handle != NULL) {
                    dkOpenMain = (void (*)(UIViewController *))dlsym(handle, "DKSettingsOpenMain");
                }
            }
            if (dkOpenMain != NULL) {
                
                
                DPOBeginActivation(activeFeature.pluginImage);
                @try {
                    dkOpenMain(presenter);
                } @catch (NSException *exception) {
                    DPOLogEvent(@"ERROR", @"DKSettingsOpenMain 异常：%@", exception.reason);
                }
                UINavigationController *dkNav = presenter.navigationController;
                if (dkNav != nil && dkNav.topViewController != presenter) {
                    DPOLogEvent(@"ACT", @"用 DKSettingsOpenMain 打开 DYKiller");
                    return;
                }
            }
        }

        
        AWESettingBaseViewModel *delegateViewModel = liveViewModel ?: activeFeature.viewModel;
        id previousDelegate = nil;
        if (delegateViewModel != nil && presenter != nil) {
            previousDelegate = delegateViewModel.controllerDelegate;
            @try {
                delegateViewModel.controllerDelegate = presenter;
            } @catch (__unused NSException *exception) {
            }
        }

        DPOBeginActivation(activeFeature.pluginImage);
        DPOGuardBeginActivation(activeFeature.key);

        @try {
            block();
            DPOLogEvent(@"ACT", @"已执行插件 block：%@", activeFeature.title);
        } @catch (NSException *exception) {
            NSLog(@"[PluginNest] 插件点击回调异常：%@", exception.reason);
            DPOLogEvent(@"ERROR", @"插件点击回调异常：%@ %@", exception.name, exception.reason);
        }

        
        NSString *guardKey = [activeFeature.key copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DPOGuardEndActivation(guardKey);
        });

        
        
        

        
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *top = DPOTopViewController();
            UIViewController *presented = top.presentedViewController;
            DPOLogEvent(@"ACT", @"执行后 0.6s：top=%@ presented=%@ cls=%@",
                        top != nil ? NSStringFromClass([top class]) : @"(nil)",
                        presented != nil ? NSStringFromClass([presented class]) : @"(nil)",
                        item.cellControllerClass.length > 0 ? item.cellControllerClass : @"-");

            [self dpo_openStreakHelperIfNeeded:activeFeature from:top];

            
            NSString *imageName = activeFeature.pluginImage.lastPathComponent ?: @"";
            BOOL inlinePanel = [imageName containsString:@"AwemeX"];       
            BOOL ownWindow = [imageName containsString:@"DouyinHelper"];   
            if (!inlinePanel && !ownWindow) {
                UIViewController *currentTop = DPOTopViewController();
                if (currentTop == presenter && presenter.presentedViewController == nil) {
                    [DPOToast show:[NSString stringWithFormat:@"%@ 没有响应", activeFeature.title]];
                }
            }
        });

        if (delegateViewModel != nil && presenter != nil) {
            __weak AWESettingBaseViewModel *weakViewModel = delegateViewModel;
            id strongPrevious = previousDelegate;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AWESettingBaseViewModel *aliveViewModel = weakViewModel;
                if (aliveViewModel == nil) return;
                id current = aliveViewModel.controllerDelegate;
                if (current == presenter || current == nil) {
                    @try {
                        aliveViewModel.controllerDelegate = strongPrevious;
                    } @catch (__unused NSException *exception) {
                    }
                }
            });
        }

        
        
        
    });
}

+ (void)dpo_openStreakHelperIfNeeded:(DPOFeature *)feature from:(UIViewController *)top {
    NSString *imageName = feature.pluginImage.lastPathComponent ?: @"";
    if (![imageName containsString:@"DYYYStreakHelper"]) return;
    if (top == nil) return;

    Class panelClass = NSClassFromString(@"AWEStreakHelperViewController");
    if (panelClass == Nil) return;

    
    
    NSString *topName = NSStringFromClass([top class]);
    BOOL onSettingsStack = [top isKindOfClass:[DPOOrganizerViewController class]] ||
                           [topName containsString:@"Settings"];
    if (!onSettingsStack) return;

    
    if ([top isKindOfClass:panelClass]) return;
    if ([top.presentedViewController isKindOfClass:panelClass]) return;

    UIViewController *panel = nil;
    @try {
        panel = [[panelClass alloc] init];
    } @catch (NSException *exception) {
        DPOLogEvent(@"ERROR", @"续火花面板创建失败：%@", exception.reason);
        return;
    }
    if (panel == nil) return;

    @try {
        UINavigationController *nav = top.navigationController;
        if (nav != nil) {
            [nav pushViewController:panel animated:YES];
        } else {
            UINavigationController *wrapper =
                [[UINavigationController alloc] initWithRootViewController:panel];
            wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
            [top presentViewController:wrapper animated:YES completion:nil];
        }
        DPOLogEvent(@"ACT", @"直接打开续火花面板（block 未响应）");
    } @catch (NSException *exception) {
        DPOLogEvent(@"ERROR", @"续火花面板打开失败：%@", exception.reason);
    }
}

+ (void)dpo_openPluginPageForDeepFeature:(DPOFeature *)feature from:(UIViewController *)host {
    NSArray<DPOPluginGroup *> *groups = [DPOFeatureStore shared].groups;

    DPOPluginGroup *targetGroup = nil;
    for (DPOPluginGroup *group in groups) {
        if ([group.imagePath isEqualToString:feature.pluginImage]) {
            targetGroup = group;
            break;
        }
    }

    // 深层索引落盘时存的是完整路径，仓库里的 imagePath 可能是另一条等价路径
    // （/var/jb 与 /private/preboot 之类），退化成「同 dylib 文件名」再匹配一次。
    if (targetGroup == nil && feature.pluginImage.length > 0) {
        NSString *wanted = DPOPluginIdentity(feature.pluginImage);
        for (DPOPluginGroup *group in groups) {
            if ([DPOPluginIdentity(group.imagePath) isEqualToString:wanted]) {
                targetGroup = group;
                DPOLogEvent(@"LOCATE", @"按 identity 匹配到分组：%@", group.name);
                break;
            }
        }
    }

    if (targetGroup != nil) {
        for (DPOFeature *candidate in targetGroup.features) {
            if (candidate.isDeep || candidate.isSwitch) continue;
            if (candidate.item.cellTappedBlock == nil) continue;
            [self activateFeature:candidate from:host];
            return;
        }
    }

    // 这个插件在设置页没有可点的入口行（被别的插件代管、或压根没注册）——
    // 直接反射它镜像里的设置页 VC，比弹提示有用。
    DPOLogEvent(@"LOCATE", @"没有可用入口，尝试直接打开：%@",
                feature.pluginImage.lastPathComponent);
    if ([self openPluginSettingsPageForImage:feature.pluginImage from:host]) return;

    [DPOToast show:@"请先打开抖音设置页加载插件"];
}

+ (void)toggleFeature:(DPOFeature *)feature {
    if (feature == nil) return;
    BOOL current = feature.item != nil ? feature.item.isSwitchOn : feature.isOn;
    [self setFeature:feature enabled:!current];
}

+ (void)setFeature:(DPOFeature *)feature enabled:(BOOL)enabled {
    if (feature == nil) return;

    DPORunOnMain(^{
        AWESettingItemModel *item = feature.item;

        
        
        if (item == nil) {
            [DPOToast show:@"插件尚未加载，请先打开抖音设置页"];
            return;
        }

        BOOL previous = item.isSwitchOn;
        feature.isOn = enabled;
        item.isSwitchOn = enabled;
        DPOLogEvent(@"TOGGLE", @"%@ → %@", feature.title, enabled ? @"ON" : @"OFF");

        void (^changed)(BOOL) = item.switchChangedBlock;
        if (changed != nil) {
            @try {
                changed(enabled);
            } @catch (NSException *exception) {
                // 回调抛异常说明插件内部并没有真正切换：把开关状态回滚，
                // 否则界面会永远停在「已开启而插件没开」的假状态。
                feature.isOn = previous;
                item.isSwitchOn = previous;
                NSLog(@"[PluginNest] 插件开关回调异常：%@", exception.reason);
            }
        }

        if ([item respondsToSelector:@selector(refreshCell)]) {
            @try {
                [item refreshCell];
            } @catch (__unused NSException *exception) {
            }
        }

        DPOHapticImpact(UIImpactFeedbackStyleLight);
        [[NSNotificationCenter defaultCenter] postNotificationName:DPOFeatureStateDidChangeNotification
                                                            object:feature
                                                          userInfo:@{ @"key": feature.key ?: @"" }];
    });
}

+ (void)forceRefreshFromViewModel:(AWESettingBaseViewModel *)vm {
    if (vm == nil) return;

    DPORunOnMain(^{
        @try {
            if ([vm respondsToSelector:@selector(sectionDataArray)]) {
                (void)[vm sectionDataArray];
            }
        } @catch (NSException *exception) {
            NSLog(@"[PluginNest] 刷新宿主数据异常：%@", exception.reason);
        }
    });
}

+ (DPODiagnosticEntry *)dpo_diagnosticForItem:(AWESettingItemModel *)item
                                      section:(AWESettingSectionModel *)section
                                        owner:(NSString *)owner {
    DPODiagnosticEntry *entry = [[DPODiagnosticEntry alloc] init];
    entry.title = DPOSafeString(item.title);
    entry.identifier = DPOSafeString(item.identifier);
    entry.section = DPOSafeString(section.sectionHeaderTitle);
    entry.owner = owner.length > 0 ? owner : @"";

    NSString *blockPath = DPOPluginImageForBlock(item.cellTappedBlock);
    if (blockPath.length == 0) blockPath = DPOPluginImageForBlock(item.switchChangedBlock);
    entry.blockImage = blockPath.length > 0 ? blockPath : @"";

    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    if (item.cellControllerClass.length > 0) [classes addObject:item.cellControllerClass];
    if (item.bizViewModelClass.length > 0) [classes addObject:item.bizViewModelClass];
    entry.classInfo = [classes componentsJoinedByString:@", "];

    return entry;
}

@end
