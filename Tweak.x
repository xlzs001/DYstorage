

#import "DPOCommon.h"
#import "DPORuntime.h"
#import "DPOHarvester.h"
#import "DPOPackageResolver.h"
#import "DPOLogCenter.h"

#pragma mark - Hook 实现

static NSArray *(*DPOOriginalMainSectionDataArray)(id, SEL) = NULL;
static NSArray *(*DPOOriginalMainSectionDataArray2)(id, SEL) = NULL;
static NSArray *(*DPOOriginalMainSectionDataArray3)(id, SEL) = NULL;
static NSArray *(*DPOOriginalMainSectionDataArray4)(id, SEL) = NULL;
static NSArray *(*DPOOriginalMainSectionDataArray5)(id, SEL) = NULL;
static NSArray *(*DPOOriginalMainSectionDataArray6)(id, SEL) = NULL;
static NSArray *(*DPOOriginalBaseSectionDataArray)(id, SEL) = NULL;

static NSInteger DPOActiveHookLevel = 1;

static BOOL DPOInstallOuterSectionHook(void);
static void DPOInstallViewDidAppearHook(void);
static void DPOInstallContainerHooks(void);
static void DPOInstallTableHooks(void);

static NSArray *DPOHandleMainSections(id self, SEL _cmd,
                                      NSArray *(*original)(id, SEL),
                                      NSInteger level) {
    NSArray *sections = original != NULL ? original(self, _cmd) : nil;

    
    if (level != DPOActiveHookLevel) return sections;

    
    
    
    
    DPOSettingsViewModelKind kind = DPOClassifySettingsViewModel(self);
    if (kind == DPOSettingsViewModelKindUnknown) return sections;

    if (kind == DPOSettingsViewModelKindSubPage) {
        @try {
            return [DPOHarvester handleSubPageViewModel:(AWESettingBaseViewModel *)self sections:sections];
        } @catch (__unused NSException *exception) {
            return sections;
        }
    }

    @try {
        return [DPOHarvester handleMainViewModel:(AWESettingBaseViewModel *)self sections:sections];
    } @catch (NSException *exception) {
        DPOLog(@"处理设置页异常：%@", exception.reason);
        return sections;
    }
}

static NSArray *DPOHookedMainSectionDataArray(id self, SEL _cmd) {
    return DPOHandleMainSections(self, _cmd, DPOOriginalMainSectionDataArray, 1);
}

static NSArray *DPOHookedMainSectionDataArray2(id self, SEL _cmd) {
    return DPOHandleMainSections(self, _cmd, DPOOriginalMainSectionDataArray2, 2);
}

static NSArray *DPOHookedMainSectionDataArray3(id self, SEL _cmd) {
    return DPOHandleMainSections(self, _cmd, DPOOriginalMainSectionDataArray3, 3);
}

static NSArray *DPOHookedMainSectionDataArray4(id self, SEL _cmd) {
    return DPOHandleMainSections(self, _cmd, DPOOriginalMainSectionDataArray4, 4);
}

static NSArray *DPOHookedMainSectionDataArray5(id self, SEL _cmd) {
    return DPOHandleMainSections(self, _cmd, DPOOriginalMainSectionDataArray5, 5);
}

static NSArray *DPOHookedMainSectionDataArray6(id self, SEL _cmd) {
    return DPOHandleMainSections(self, _cmd, DPOOriginalMainSectionDataArray6, 6);
}

static NSArray *DPOHookedBaseSectionDataArray(id self, SEL _cmd) {
    NSArray *sections = DPOOriginalBaseSectionDataArray != NULL
                            ? DPOOriginalBaseSectionDataArray(self, _cmd)
                            : nil;

    if (!DPOIsMainSettingsViewModel(self)) {
        
        
        if (DPOClassifySettingsViewModel(self) != DPOSettingsViewModelKindSubPage) return sections;
        @try {
            return [DPOHarvester handleSubPageViewModel:(AWESettingBaseViewModel *)self sections:sections];
        } @catch (__unused NSException *exception) {
        }
    }
    return sections;
}

#pragma mark - 设置页出现后补扫

static void (*DPOOriginalBaseViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*DPOOriginalTableVCDidAppear)(id, SEL, BOOL) = NULL;

static void DPOPerformSettingsRescan(id controller) {
    if (controller == nil) return;

    id viewModel = nil;
    @try {
        viewModel = [controller valueForKey:@"viewModel"];
    } @catch (__unused NSException *exception) {
    }
    if (!DPOIsMainSettingsViewModel(viewModel)) return;

    NSUInteger beforeFeatures = [DPOFeatureStore shared].featureCount;
    NSUInteger beforeChanges = [DPOHarvester harvestChangeCount];

    NSArray *currentSections = nil;
    @try {
        currentSections = [(AWESettingBaseViewModel *)viewModel sectionDataArray];
    } @catch (__unused NSException *exception) {
    }

    NSUInteger leftovers = [DPOHarvester countThirdPartyItemsInSections:currentSections];
    if (leftovers > 0) {
        DPOLogEvent(@"RESCAN", @"仍有 %lu 个第三方入口残留在设置页", (unsigned long)leftovers);

        
        
        NSUInteger purged = [DPOHarvester purgeThirdPartyItemsInSections:currentSections];
        BOOL upgraded = DPOInstallOuterSectionHook();

        if (purged > 0 || upgraded) {
            UITableView *tableView = nil;
            @try {
                tableView = [controller valueForKey:@"tableView"];
            } @catch (__unused NSException *exception) {
            }
            [tableView reloadData];
            DPOLogEvent(@"RESCAN", @"已清理 %lu 条残留（补挂 hook：%@）",
                        (unsigned long)purged, upgraded ? @"是" : @"否");
        }
    }

    
    NSUInteger afterFeatures = [DPOFeatureStore shared].featureCount;
    NSUInteger afterChanges = [DPOHarvester harvestChangeCount];
    BOOL changed = (afterFeatures != beforeFeatures) || (afterChanges != beforeChanges);

    DPOLogEvent(@"RESCAN", @"%@ 功能 %lu→%lu 收走 %lu→%lu %@",
                NSStringFromClass([controller class]),
                (unsigned long)beforeFeatures, (unsigned long)afterFeatures,
                (unsigned long)beforeChanges, (unsigned long)afterChanges,
                changed ? @"reload" : @"skip");
    if (!changed) return;

    UITableView *tableView = nil;
    @try {
        tableView = [controller valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void DPOScheduleSettingsRescan(id controller) {
    static NSTimeInterval lastRescan = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - lastRescan < 0.6) return;
    lastRescan = now;

    
    for (NSNumber *delay in @[ @0.30, @1.10 ]) {
        __weak id weakController = controller;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DPOPerformSettingsRescan(weakController);
        });
    }
}

static void DPOScheduleLateProbe(id controller, NSInteger attempt);

static void DPOScheduleLateProbe(id controller, NSInteger attempt) {
    if (attempt >= 2) return;

    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongController = weakController;
        if (strongController == nil) return;

        id viewModel = nil;
        @try {
            viewModel = [strongController valueForKey:@"viewModel"];
        } @catch (__unused NSException *exception) {
        }
        if (!DPOIsMainSettingsViewModel(viewModel)) return;

        NSArray *sections = nil;
        @try {
            sections = [(AWESettingBaseViewModel *)viewModel sectionDataArray];
        } @catch (__unused NSException *exception) {
        }

        NSUInteger collected = [DPOHarvester collectAndRemoveThirdPartyItemsInSections:sections];
        if (collected > 0) {
            
            [DPOHarvester setForceNextHarvest:YES];
            @try {
                (void)[(AWESettingBaseViewModel *)viewModel sectionDataArray];
            } @catch (__unused NSException *exception) {
            }

            UITableView *tableView = nil;
            @try {
                tableView = [strongController valueForKey:@"tableView"];
            } @catch (__unused NSException *exception) {
            }
            [tableView reloadData];
            DPOLogEvent(@"LATE", @"延时兜底收录 %lu 条并刷新", (unsigned long)collected);
        }

        DPOScheduleLateProbe(strongController, attempt + 1);
    });
}

static void DPOScheduleBootstrapCleanup(id controller) {
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;

    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongController = weakController;
        if (strongController == nil) return;

        id viewModel = nil;
        @try {
            viewModel = [strongController valueForKey:@"viewModel"];
        } @catch (__unused NSException *exception) {
        }
        if (!DPOIsMainSettingsViewModel(viewModel)) {
            
            scheduled = NO;
            return;
        }

        DPOInstallOuterSectionHook();

        
        [DPOHarvester setForceNextHarvest:YES];
        NSArray *sections = nil;
        @try {
            sections = [(AWESettingBaseViewModel *)viewModel sectionDataArray];
        } @catch (__unused NSException *exception) {
        }

        
        NSUInteger collected = [DPOHarvester collectAndRemoveThirdPartyItemsInSections:sections];

        
        [DPOHarvester setForceNextHarvest:YES];
        @try {
            (void)[(AWESettingBaseViewModel *)viewModel sectionDataArray];
        } @catch (__unused NSException *exception) {
        }

        UITableView *tableView = nil;
        @try {
            tableView = [strongController valueForKey:@"tableView"];
        } @catch (__unused NSException *exception) {
        }
        [tableView reloadData];

        DPOLogEvent(@"BOOTSTRAP", @"一次性收纳完成，补收 %lu 条，之后只做两次延时兜底",
                    (unsigned long)collected);

        DPOScheduleLateProbe(strongController, 0);
    });
}

static void DPOHookedBaseViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (DPOOriginalBaseViewDidAppear != NULL) {
        DPOOriginalBaseViewDidAppear(self, _cmd, animated);
    }
    DPOScheduleBootstrapCleanup(self);
}

static void DPOHookedTableVCDidAppear(id self, SEL _cmd, BOOL animated) {
    if (DPOOriginalTableVCDidAppear != NULL) {
        DPOOriginalTableVCDidAppear(self, _cmd, animated);
    }
    DPOScheduleBootstrapCleanup(self);
}

static void (*DPOOriginalMainVCWillAppear)(id, SEL, BOOL) = NULL;

static void DPOHookedMainVCWillAppear(id self, SEL _cmd, BOOL animated) {
    static BOOL installedOnce = NO;
    if (!installedOnce) {
        installedOnce = YES;
        DPOInstallOuterSectionHook();
    }

    
    
    DPOInstallViewDidAppearHook();
    DPOInstallContainerHooks();
    DPOInstallTableHooks();

    @try {
        id viewModel = [self valueForKey:@"viewModel"];
        if (viewModel != nil) DPOSetMainSettingsViewModel(viewModel);
    } @catch (__unused NSException *exception) {
    }
    if (DPOOriginalMainVCWillAppear != NULL) {
        DPOOriginalMainVCWillAppear(self, _cmd, animated);
    }
}

#pragma mark - 插入 API 归属捕获

static void (*DPOOriginalInsertSection)(id, SEL, id, long long) = NULL;
static void (*DPOOriginalInsertItem)(id, SEL, long long, id) = NULL;
static void (*DPOOriginalSetItemArray)(id, SEL, id) = NULL;
static void (*DPOOriginalSetTapBlock)(id, SEL, id) = NULL;
static void (*DPOOriginalSetSwitchBlock)(id, SEL, id) = NULL;

static void DPOHookedInsertSection(id self, SEL _cmd, id section, long long index) {
    @try {
        DPOCaptureOwnerForObject(section);
    } @catch (__unused NSException *exception) {
    }
    if (DPOOriginalInsertSection != NULL) {
        DPOOriginalInsertSection(self, _cmd, section, index);
    }
}

static void DPOHookedInsertItem(id self, SEL _cmd, long long type, id path) {
    if (DPOOriginalInsertItem != NULL) {
        DPOOriginalInsertItem(self, _cmd, type, path);
    }
    @try {
        if ([self respondsToSelector:@selector(itemModelWithType:)]) {
            id item = [self itemModelWithType:type];
            DPOCaptureOwnerForObject(item);
        }
    } @catch (__unused NSException *exception) {
    }
}

static void DPOHookedSetItemArray(id self, SEL _cmd, id items) {
    if (DPOOriginalSetItemArray != NULL) {
        DPOOriginalSetItemArray(self, _cmd, items);
    }
    @try {
        DPOCaptureOwnerForObject(self);
    } @catch (__unused NSException *exception) {
    }
}

static void DPOHookedSetTapBlock(id self, SEL _cmd, id block) {
    if (DPOOriginalSetTapBlock != NULL) {
        DPOOriginalSetTapBlock(self, _cmd, block);
    }
    @try {
        DPOCaptureOwnerForObject(self);
    } @catch (__unused NSException *exception) {
    }
}

static void DPOHookedSetSwitchBlock(id self, SEL _cmd, id block) {
    if (DPOOriginalSetSwitchBlock != NULL) {
        DPOOriginalSetSwitchBlock(self, _cmd, block);
    }
    @try {
        DPOCaptureOwnerForObject(self);
    } @catch (__unused NSException *exception) {
    }
}

#pragma mark - 安装

static Class DPOOwnerOfSelector(Class cls, SEL selector) {
    Class cursor = cls;
    while (cursor != Nil) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cursor, &count);
        BOOL found = NO;
        if (methods != NULL) {
            for (unsigned int i = 0; i < count; i++) {
                if (method_getName(methods[i]) == selector) {
                    found = YES;
                    break;
                }
            }
            free(methods);
        }
        if (found) return cursor;
        cursor = class_getSuperclass(cursor);
    }
    return Nil;
}

static BOOL DPOInstallOuterSectionHook(void) {
    static NSInteger installedLevel = 1;
    if (installedLevel >= 6) return NO;

    Class settingsClass = DPOLookupClass("AWESettingsViewModel");
    Class baseClass = DPOLookupClass("AWESettingBaseViewModel");
    SEL selector = @selector(sectionDataArray);

    Class owner = Nil;
    if (settingsClass != Nil) owner = DPOOwnerOfSelector(settingsClass, selector);
    if (owner == Nil && baseClass != Nil) owner = DPOOwnerOfSelector(baseClass, selector);
    if (owner == Nil) return NO;

    installedLevel += 1;

    IMP newIMP = NULL;
    IMP *originalSlot = NULL;
    switch (installedLevel) {
        case 2:
            newIMP = (IMP)DPOHookedMainSectionDataArray2;
            originalSlot = (IMP *)&DPOOriginalMainSectionDataArray2;
            break;
        case 3:
            newIMP = (IMP)DPOHookedMainSectionDataArray3;
            originalSlot = (IMP *)&DPOOriginalMainSectionDataArray3;
            break;
        case 4:
            newIMP = (IMP)DPOHookedMainSectionDataArray4;
            originalSlot = (IMP *)&DPOOriginalMainSectionDataArray4;
            break;
        case 5:
            newIMP = (IMP)DPOHookedMainSectionDataArray5;
            originalSlot = (IMP *)&DPOOriginalMainSectionDataArray5;
            break;
        default:
            newIMP = (IMP)DPOHookedMainSectionDataArray6;
            originalSlot = (IMP *)&DPOOriginalMainSectionDataArray6;
            break;
    }
    if (newIMP == NULL || originalSlot == NULL) {
        installedLevel -= 1;
        return NO;
    }

    MSHookMessageEx(owner, selector, newIMP, originalSlot);

    // 校验补挂是否真的生效。若 owner 上取到的仍不是新 IMP（插件自己也 hook 了
    // 同一个方法、或 hook 引擎拒绝），就不能推进 DPOActiveHookLevel：否则这一层
    // 会「吃掉」所有 sectionDataArray 调用却从不处理，界面会整页空白。
    if (class_getMethodImplementation(owner, selector) != newIMP) {
        NSInteger failedLevel = installedLevel;
        installedLevel -= 1;
        DPOLogEvent(@"HOOK", @"补挂 L%ld 被拒：%@@%@", (long)failedLevel,
                    NSStringFromClass(owner), NSStringFromSelector(selector));
        return NO;
    }

    DPOActiveHookLevel = installedLevel;
    DPOLogEvent(@"HOOK", @"补挂外层 hook L%ld：%@",
                (long)installedLevel, NSStringFromClass(owner));
    return YES;
}

static void DPOInstallViewDidAppearHook(void) {
    static BOOL installed = NO;
    if (installed) return;

    SEL sel = @selector(viewDidAppear:);
    BOOL hookedAny = NO;

    Class baseClass = DPOLookupClass("AWESettingBaseViewController");
    if (baseClass != Nil && DPOOwnerOfSelector(baseClass, sel) == baseClass) {
        Method method = class_getInstanceMethod(baseClass, sel);
        const char *types = method != NULL ? method_getTypeEncoding(method) : NULL;
        if (types != NULL && types[0] == _C_VOID) {
            MSHookMessageEx(baseClass, sel,
                            (IMP)DPOHookedBaseViewDidAppear,
                            (IMP *)&DPOOriginalBaseViewDidAppear);
            hookedAny = YES;
            DPOLog(@"已挂钩 %@.viewDidAppear:", NSStringFromClass(baseClass));
        }
    }

    Class tableClass = DPOLookupClass("AWESettingsTableViewController");
    if (tableClass != Nil) {
        SEL willAppearSelector = @selector(viewWillAppear:);
        if (DPOOwnerOfSelector(tableClass, willAppearSelector) == tableClass) {
            MSHookMessageEx(tableClass, willAppearSelector,
                            (IMP)DPOHookedMainVCWillAppear,
                            (IMP *)&DPOOriginalMainVCWillAppear);
            hookedAny = YES;
            DPOLog(@"已挂钩 %@.viewWillAppear:", NSStringFromClass(tableClass));
        }

        Method method = class_getInstanceMethod(tableClass, sel);
        const char *types = method != NULL ? method_getTypeEncoding(method) : NULL;
        if (types != NULL && types[0] == _C_VOID) {
            MSHookMessageEx(tableClass, sel,
                            (IMP)DPOHookedTableVCDidAppear,
                            (IMP *)&DPOOriginalTableVCDidAppear);
            hookedAny = YES;
            DPOLog(@"已挂钩 %@.viewDidAppear:", NSStringFromClass(tableClass));
        }
    }

    installed = hookedAny;
    DPOLogEvent(@"HOOK", @"设置页出现监听安装%@", hookedAny ? @"成功" : @"失败（类未就绪）");
}

static void DPOInstallContainerHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    BOOL hookedAny = NO;

    Class vmClass = DPOLookupClass("AWESettingBaseViewModel");
    if (vmClass != Nil) {
        SEL insertSection = @selector(insertSectionModel:toIndex:);
        if (DPOOwnerOfSelector(vmClass, insertSection) != Nil) {
            MSHookMessageEx(vmClass, insertSection,
                            (IMP)DPOHookedInsertSection,
                            (IMP *)&DPOOriginalInsertSection);
            hookedAny = YES;
        }

        SEL insertItem = @selector(insertItemModelWithType:toPath:);
        if (DPOOwnerOfSelector(vmClass, insertItem) != Nil) {
            MSHookMessageEx(vmClass, insertItem,
                            (IMP)DPOHookedInsertItem,
                            (IMP *)&DPOOriginalInsertItem);
            hookedAny = YES;
        }
    }

    Class sectionClass = DPOLookupClass("AWESettingSectionModel");
    if (sectionClass != Nil) {
        SEL setItems = @selector(setItemArray:);
        if (DPOOwnerOfSelector(sectionClass, setItems) == sectionClass) {
            MSHookMessageEx(sectionClass, setItems,
                            (IMP)DPOHookedSetItemArray,
                            (IMP *)&DPOOriginalSetItemArray);
            hookedAny = YES;
        }
    }

    
    Class itemClass = DPOLookupClass("AWESettingItemModel");
    if (itemClass != Nil) {
        SEL setTap = @selector(setCellTappedBlock:);
        if (DPOOwnerOfSelector(itemClass, setTap) == itemClass) {
            MSHookMessageEx(itemClass, setTap,
                            (IMP)DPOHookedSetTapBlock,
                            (IMP *)&DPOOriginalSetTapBlock);
            hookedAny = YES;
        }
        SEL setSwitch = @selector(setSwitchChangedBlock:);
        if (DPOOwnerOfSelector(itemClass, setSwitch) == itemClass) {
            MSHookMessageEx(itemClass, setSwitch,
                            (IMP)DPOHookedSetSwitchBlock,
                            (IMP *)&DPOOriginalSetSwitchBlock);
            hookedAny = YES;
        }
    }

    if (!hookedAny) {
        DPOLogEvent(@"HOOK", @"设置页模型类尚未注册，插入 API 监听稍后重试");
        return;
    }

    installed = YES;
    DPOLog(@"已挂钩设置项插入 API");
    DPOLogEvent(@"HOOK", @"设置项插入 / block setter 监听已安装");
}

#pragma mark - 说明

#pragma mark - 表格层隐藏残留入口

static CGFloat (*DPOOriginalHeightForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static UITableViewCell *(*DPOOriginalCellForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static NSArray *DPOSectionsForController(id controller) {
    id viewModel = nil;
    @try {
        viewModel = [controller valueForKey:@"viewModel"];
    } @catch (__unused NSException *exception) {
    }
    if (viewModel == nil) return nil;

    
    
    
    NSString *controllerName = NSStringFromClass([controller class]);
    BOOL isMainController = [controllerName containsString:@"SettingsTableViewController"];
    if (isMainController && viewModel == [DPOHarvester lastProcessedViewModel]) {
        NSArray *snapshot = [DPOHarvester lastProcessedSections];
        if (snapshot != nil) return snapshot;
    }

    static __weak id cachedViewModel = nil;
    static NSTimeInterval cachedAt = 0;
    static NSArray *cachedSections = nil;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (viewModel == cachedViewModel && now - cachedAt < 0.3) return cachedSections;

    NSArray *sections = nil;
    @try {
        sections = [viewModel sectionDataArray];
    } @catch (__unused NSException *exception) {
    }
    cachedViewModel = viewModel;
    cachedAt = now;
    cachedSections = sections;
    return sections;
}

static BOOL DPORowIsThirdPartyEntry(id controller, NSIndexPath *indexPath) {
    if (indexPath == nil) return NO;

    
    
    id viewModel = nil;
    @try {
        viewModel = [controller valueForKey:@"viewModel"];
    } @catch (__unused NSException *exception) {
    }
    if (!DPOIsMainSettingsViewModel(viewModel)) return NO;

    NSArray *sections = DPOSectionsForController(controller);
    if (indexPath.section < 0 || (NSUInteger)indexPath.section >= sections.count) return NO;

    id section = sections[(NSUInteger)indexPath.section];
    Class sectionClass = objc_getClass("AWESettingSectionModel");
    if (sectionClass == Nil || ![section isKindOfClass:sectionClass]) return NO;

    NSArray *items = ((AWESettingSectionModel *)section).itemArray;
    if (![items isKindOfClass:[NSArray class]]) return NO;
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= items.count) return NO;

    id item = items[(NSUInteger)indexPath.row];
    Class itemClass = objc_getClass("AWESettingItemModel");
    if (itemClass == Nil || ![item isKindOfClass:itemClass]) return NO;

    NSString *identifier = DPOSafeString(((AWESettingItemModel *)item).identifier);
    if ([identifier hasPrefix:DPOEntryIdentifier]) return NO;

    
    return [DPOHarvester isCollectedIdentifier:identifier];
}

static NSInteger (*DPOOriginalNumberOfRows)(id, SEL, UITableView *, NSInteger) = NULL;
static NSInteger (*DPOOriginalNumberOfSections)(id, SEL, UITableView *) = NULL;
static void (*DPOOriginalDidSelectRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static NSArray<NSDictionary *> *DPORowMapForController(id controller) {
    
    

    id viewModel = nil;
    @try {
        viewModel = [controller valueForKey:@"viewModel"];
    } @catch (__unused NSException *exception) {
    }
    if (viewModel == nil) return nil;

    // 只有「主设置页」才按 DPOCollectedIdentifiers 隐藏行。
    // 插件自己的设置页也是 AWESettingBaseViewController，如果照旧隐藏，
    // 插件复用了主页面同一个 identifier 时，它自己的功能行会整行消失
    // （1.1.36/37 的同类问题）。子页一律做恒等映射。
    BOOL subPage = (DPOClassifySettingsViewModel(viewModel) == DPOSettingsViewModelKindSubPage);

    NSArray *sections = nil;
    @try {
        sections = [viewModel sectionDataArray];
    } @catch (__unused NSException *exception) {
    }
    if (![sections isKindOfClass:[NSArray class]]) return nil;

    Class sectionClass = objc_getClass("AWESettingSectionModel");
    Class itemClass = objc_getClass("AWESettingItemModel");
    if (sectionClass == Nil || itemClass == Nil) return nil;

    NSMutableArray<NSDictionary *> *map = [NSMutableArray arrayWithCapacity:sections.count];
    for (NSUInteger sectionIndex = 0; sectionIndex < sections.count; sectionIndex++) {
        id sectionObject = sections[sectionIndex];
        NSMutableArray<NSNumber *> *rows = [NSMutableArray array];

        if ([sectionObject isKindOfClass:sectionClass]) {
            NSArray *items = ((AWESettingSectionModel *)sectionObject).itemArray;
            if ([items isKindOfClass:[NSArray class]]) {
                for (NSUInteger index = 0; index < items.count; index++) {
                    id item = items[index];
                    if (![item isKindOfClass:itemClass]) {
                        [rows addObject:@(index)];
                        continue;
                    }
                    NSString *identifier = DPOSafeString(((AWESettingItemModel *)item).identifier);
                    if (!subPage && identifier.length > 0 &&
                        [DPOHarvester isCollectedIdentifier:identifier]) {
                        continue;
                    }
                    [rows addObject:@(index)];
                }
            }
        }

        
        [map addObject:@{ @"section": @(sectionIndex), @"rows": rows }];
    }

    return [map copy];
}

static NSIndexPath *DPOMappedIndexPath(id controller, NSIndexPath *indexPath) {
    NSArray<NSDictionary *> *map = DPORowMapForController(controller);
    if (map == nil || indexPath.section < 0 || (NSUInteger)indexPath.section >= map.count) return indexPath;

    NSDictionary *entry = map[(NSUInteger)indexPath.section];
    NSArray<NSNumber *> *rows = entry[@"rows"];
    NSNumber *originalSection = entry[@"section"];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= rows.count) return nil;

    return [NSIndexPath indexPathForRow:[rows[(NSUInteger)indexPath.row] integerValue]
                              inSection:originalSection.integerValue];
}

static NSInteger DPOHookedNumberOfSections(id self, SEL _cmd, UITableView *tableView) {
    NSArray<NSDictionary *> *map = DPORowMapForController(self);
    if (map != nil) return (NSInteger)map.count;
    return DPOOriginalNumberOfSections != NULL ? DPOOriginalNumberOfSections(self, _cmd, tableView) : 0;
}

static NSInteger DPOHookedNumberOfRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSArray<NSDictionary *> *map = DPORowMapForController(self);
    if (map != nil) {
        if (section < 0 || (NSUInteger)section >= map.count) return 0;
        return (NSInteger)[(NSArray *)map[(NSUInteger)section][@"rows"] count];
    }
    return DPOOriginalNumberOfRows != NULL
               ? DPOOriginalNumberOfRows(self, _cmd, tableView, section)
               : 0;
}

static CGFloat DPOHookedHeightForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSIndexPath *mapped = DPOMappedIndexPath(self, indexPath);
    if (mapped == nil) return 0.01;
    return DPOOriginalHeightForRow != NULL
               ? DPOOriginalHeightForRow(self, _cmd, tableView, mapped)
               : 44.0;
}

static UITableViewCell *DPOHookedCellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSIndexPath *mapped = DPOMappedIndexPath(self, indexPath);
    if (mapped == nil) {
        return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    }
    return DPOOriginalCellForRow != NULL
               ? DPOOriginalCellForRow(self, _cmd, tableView, mapped)
               : nil;
}

static void DPOHookedDidSelectRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSIndexPath *mapped = DPOMappedIndexPath(self, indexPath);
    if (mapped == nil) return;
    if (DPOOriginalDidSelectRow != NULL) {
        DPOOriginalDidSelectRow(self, _cmd, tableView, mapped);
    }
}

static CGFloat (*DPOOriginalHeightForHeader)(id, SEL, UITableView *, NSInteger) = NULL;
static UIView *(*DPOOriginalViewForHeader)(id, SEL, UITableView *, NSInteger) = NULL;

static BOOL DPOSectionIsEmptyForController(id controller, NSInteger section) {
    NSArray<NSDictionary *> *map = DPORowMapForController(controller);
    if (map == nil || section < 0 || (NSUInteger)section >= map.count) return NO;
    id rows = map[(NSUInteger)section][@"rows"];
    return [rows isKindOfClass:[NSArray class]] && [(NSArray *)rows count] == 0;
}

static CGFloat DPOHookedHeightForHeader(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if (DPOSectionIsEmptyForController(self, section)) return 0.001;
    return DPOOriginalHeightForHeader != NULL
               ? DPOOriginalHeightForHeader(self, _cmd, tableView, section)
               : 0.01;
}

static UIView *DPOHookedViewForHeader(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if (DPOSectionIsEmptyForController(self, section)) return nil;
    return DPOOriginalViewForHeader != NULL
               ? DPOOriginalViewForHeader(self, _cmd, tableView, section)
               : nil;
}

static NSString *(*DPOOriginalTitleForHeader)(id, SEL, UITableView *, NSInteger) = NULL;
static void (*DPOOriginalWillDisplayHeader)(id, SEL, UITableView *, UIView *, NSInteger) = NULL;

static NSString *DPOHookedTitleForHeader(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if (DPOSectionIsEmptyForController(self, section)) return nil;
    return DPOOriginalTitleForHeader != NULL
               ? DPOOriginalTitleForHeader(self, _cmd, tableView, section)
               : nil;
}

static void DPOHookedWillDisplayHeader(id self, SEL _cmd, UITableView *tableView,
                                       UIView *view, NSInteger section) {
    if (DPOOriginalWillDisplayHeader != NULL) {
        DPOOriginalWillDisplayHeader(self, _cmd, tableView, view, section);
    }
    
    
    
    BOOL empty = DPOSectionIsEmptyForController(self, section);
    if (view.hidden != empty) view.hidden = empty;
}

static void DPOInstallTableHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    Class cls = DPOLookupClass("AWESettingBaseViewController");
    if (cls == Nil) return;

    SEL sectionsSelector = @selector(numberOfSectionsInTableView:);
    BOOL sectionsHooked = NO;
    if (DPOOwnerOfSelector(cls, sectionsSelector) == cls) {
        MSHookMessageEx(cls, sectionsSelector,
                        (IMP)DPOHookedNumberOfSections,
                        (IMP *)&DPOOriginalNumberOfSections);
        sectionsHooked = YES;
    }

    
    if (!sectionsHooked) {
        installed = YES;
        DPOLogEvent(@"HOOK", @"未找到 numberOfSectionsInTableView: 实现，跳过行映射");
        return;
    }

    SEL rowsSelector = @selector(tableView:numberOfRowsInSection:);
    if (DPOOwnerOfSelector(cls, rowsSelector) == cls) {
        MSHookMessageEx(cls, rowsSelector, (IMP)DPOHookedNumberOfRows, (IMP *)&DPOOriginalNumberOfRows);
    }

    SEL heightSelector = @selector(tableView:heightForRowAtIndexPath:);
    if (DPOOwnerOfSelector(cls, heightSelector) == cls) {
        MSHookMessageEx(cls, heightSelector, (IMP)DPOHookedHeightForRow, (IMP *)&DPOOriginalHeightForRow);
    }

    SEL cellSelector = @selector(tableView:cellForRowAtIndexPath:);
    if (DPOOwnerOfSelector(cls, cellSelector) == cls) {
        MSHookMessageEx(cls, cellSelector, (IMP)DPOHookedCellForRow, (IMP *)&DPOOriginalCellForRow);
    }

    SEL selectSelector = @selector(tableView:didSelectRowAtIndexPath:);
    if (DPOOwnerOfSelector(cls, selectSelector) == cls) {
        MSHookMessageEx(cls, selectSelector, (IMP)DPOHookedDidSelectRow, (IMP *)&DPOOriginalDidSelectRow);
    }

    
    SEL headerHeightSelector = @selector(tableView:heightForHeaderInSection:);
    if (DPOOwnerOfSelector(cls, headerHeightSelector) == cls) {
        MSHookMessageEx(cls, headerHeightSelector,
                        (IMP)DPOHookedHeightForHeader,
                        (IMP *)&DPOOriginalHeightForHeader);
    }

    SEL headerViewSelector = @selector(tableView:viewForHeaderInSection:);
    if (DPOOwnerOfSelector(cls, headerViewSelector) == cls) {
        MSHookMessageEx(cls, headerViewSelector,
                        (IMP)DPOHookedViewForHeader,
                        (IMP *)&DPOOriginalViewForHeader);
    }

    SEL headerTitleSelector = @selector(tableView:titleForHeaderInSection:);
    if (DPOOwnerOfSelector(cls, headerTitleSelector) == cls) {
        MSHookMessageEx(cls, headerTitleSelector,
                        (IMP)DPOHookedTitleForHeader,
                        (IMP *)&DPOOriginalTitleForHeader);
    }

    SEL willDisplayHeaderSelector = @selector(tableView:willDisplayHeaderView:forSection:);
    if (DPOOwnerOfSelector(cls, willDisplayHeaderSelector) == cls) {
        MSHookMessageEx(cls, willDisplayHeaderSelector,
                        (IMP)DPOHookedWillDisplayHeader,
                        (IMP *)&DPOOriginalWillDisplayHeader);
    }

    installed = YES;
    DPOLogEvent(@"HOOK", @"数据源行映射 hook 已安装（rows=%@ cell=%@ select=%@）",
                DPOOriginalNumberOfRows != NULL ? @"Y" : @"N",
                DPOOriginalCellForRow != NULL ? @"Y" : @"N",
                DPOOriginalDidSelectRow != NULL ? @"Y" : @"N");
}

static BOOL DPOInstallHooks(void) {
    static BOOL installed = NO;
    if (installed) return YES;

    Class settingsClass = DPOLookupClass("AWESettingsViewModel");
    Class baseClass = DPOLookupClass("AWESettingBaseViewModel");
    if (settingsClass == Nil && baseClass == Nil) {
        DPOLogEvent(@"HOOK", @"找不到设置页 view model 类，稍后重试");
        return NO;
    }

    SEL selector = @selector(sectionDataArray);
    Class owner = Nil;

    if (settingsClass != Nil) owner = DPOOwnerOfSelector(settingsClass, selector);
    if (owner == Nil && baseClass != Nil) owner = DPOOwnerOfSelector(baseClass, selector);
    if (owner == Nil) {
        DPOLogEvent(@"HOOK", @"sectionDataArray 暂无实现，等待重试");
        return NO;
    }

    Method method = class_getInstanceMethod(owner, selector);
    if (method == NULL) return NO;

    const char *types = method_getTypeEncoding(method);
    if (types == NULL || types[0] != _C_ID) {
        DPOLog(@"sectionDataArray 返回类型异常（%s），放弃", types ?: "?");
        return NO;
    }

    MSHookMessageEx(owner, selector,
                    (IMP)DPOHookedMainSectionDataArray,
                    (IMP *)&DPOOriginalMainSectionDataArray);

    
    if (baseClass != Nil && owner != baseClass) {
        Class baseOwner = DPOOwnerOfSelector(baseClass, selector);
        if (baseOwner == baseClass) {
            MSHookMessageEx(baseClass, selector,
                            (IMP)DPOHookedBaseSectionDataArray,
                            (IMP *)&DPOOriginalBaseSectionDataArray);
        }
    }

    installed = YES;
    DPOLog(@"已挂钩 %@.sectionDataArray", NSStringFromClass(owner));
    DPOLogEvent(@"HOOK", @"sectionDataArray 已挂钩实现类：%@（settings=%@ base=%@）",
                NSStringFromClass(owner),
                settingsClass != Nil ? NSStringFromClass(settingsClass) : @"nil",
                baseClass != Nil ? NSStringFromClass(baseClass) : @"nil");

    DPOInstallViewDidAppearHook();
    DPOInstallContainerHooks();
    DPOInstallTableHooks();
    return YES;
}

static void DPOScheduleInstall(NSInteger attempt) {
    if (DPOInstallHooks()) {
        return;
    }
    if (attempt >= 30) {
        DPOLog(@"重试 %ld 次仍未安装成功", (long)attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DPOScheduleInstall(attempt + 1);
    });
}

#pragma mark - 看见即收录（插件自绘 TableView）

// 有插件不用抖音的 AWESettingSectionModel，自己搭 VC + UITableView（AwemeX 就是）。
// 这类页面的行 harvest 完全看不见，只能在实际渲染时把标题捞出来、靠「类属于哪个
// 镜像」反推归属。只对第三方类生效，宿主/系统表格一律放行。

static void (*DPOOriginalWillDisplayCell)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *) = NULL;

static void DPOHookedWillDisplayCell(id self, SEL _cmd, UITableView *tableView,
                                     UITableViewCell *cell, NSIndexPath *indexPath) {
    if (DPOOriginalWillDisplayCell != NULL) {
        DPOOriginalWillDisplayCell(self, _cmd, tableView, cell, indexPath);
    }

    @try {
        // 先做廉价的归属判断，再碰 cell。旧实现反过来：先 DPOCellTitle
        // （递归扫 UILabel + 每个 label 转窗口坐标），发现不是插件表格才 return。
        // 信息流、搜索、评论这些宿主表格每滚一屏都要白跑一遍，纯浪费主线程。
        NSString *image = DPOPluginImageForClass([(id)tableView.dataSource class]);
        if (image.length == 0) image = DPOPluginImageForClass([(id)tableView.delegate class]);
        if (image.length == 0) image = DPOPluginImageForClass([cell class]);
        if (image.length == 0) return;

        // 收纳页/日志页自己的表格不算；插件页的 cell 才收。
        UIViewController *top = DPOTopViewController();
        if (top == nil || [NSStringFromClass([top class]) hasPrefix:@"DPO"]) return;

        NSString *title = DPOCellTitle(cell);
        if (title.length == 0) return;

        [DPOHarvester captureSeenTitle:title ownerImage:image];
    } @catch (__unused NSException *exception) {
    }
}

static void DPOInstallCellCaptureHook(void) {
    static BOOL installed = NO;
    if (installed) return;

    Class cls = [UITableView class];
    SEL selector = NSSelectorFromString(@"_willDisplayCell:forRowAtIndexPath:");
    if (![cls instancesRespondToSelector:selector]) {
        DPOLogEvent(@"HOOK", @"UITableView 缺少 _willDisplayCell:，跳过看见即收录");
        return;
    }

    MSHookMessageEx(cls, selector, (IMP)DPOHookedWillDisplayCell, (IMP *)&DPOOriginalWillDisplayCell);
    installed = YES;
    DPOLogEvent(@"HOOK", @"已挂 UITableView _willDisplayCell:forRowAtIndexPath:（看见即收录）");
}

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        [[DPOLogCenter shared] start];
        DPOLogEvent(@"BOOT", @"PluginNest %@ 已加载 pid=%d", DPOBuildVersion, getpid());

        
        [DPOHarvester recoverQuarantineIfNeeded];

        
        DPOInstallContainerHooks();
        DPOInstallTableHooks();
        DPOInstallCellCaptureHook();

        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DPOScheduleInstall(0);
        });

    }
}
