// DYStorage — a conservative settings-entry organizer for Douyin tweaks.
//
// The hook intentionally operates on AWESettingsViewModel's returned data
// rather than scanning UIWindow/UIView. That keeps it confined to the settings
// page and preserves each collected item's original tap callback.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "DYStorageManager.h"
#import "DYStorageDeveloperScanner.h"
#import "DYStorageSearchCatalog.h"
#import "DYStorageSearchCoordinator.h"
#import "DYStorageRuntimeIndex.h"

#ifndef DY_STORAGE_DEBUG
#define DY_STORAGE_DEBUG 0
#endif

#if DY_STORAGE_DEBUG
#define DYStorageLog(format, ...) NSLog(@"[DYStorage] " format, ##__VA_ARGS__)
#else
#define DYStorageLog(...)
#endif

static NSString *const kDYStorageHubSectionIdentifier = @"com.xlzs001.dystorage.section";
static NSString *const kDYStorageHubEntryIdentifier = @"com.xlzs001.dystorage.open";
static NSString *const kDYStorageHubContentIdentifier = @"com.xlzs001.dystorage.content";
static NSString *const kDYStorageHubMarkerTitle = @"__DYStorage_Hub__";
// control is the single source of truth: the Makefile passes the version in as
// -DDYSTORAGE_VERSION_STRING=@"x.y.z". The fallback keeps IDE-only builds going.
#ifndef DYSTORAGE_VERSION_STRING
#define DYSTORAGE_VERSION_STRING @"1.3.0"
#endif
static NSString *const kDYStorageVersion = DYSTORAGE_VERSION_STRING;
static NSString *const kDYStorageRepositoryURL = @"https://github.com/xlzs001/DYstorage";

static void *kDYStorageViewModelAssociationKey = &kDYStorageViewModelAssociationKey;
static void *kDYStorageFallbackHiddenSectionKey = &kDYStorageFallbackHiddenSectionKey;
static void *kDYStorageSearchCoordinatorAssociationKey = &kDYStorageSearchCoordinatorAssociationKey;
static void *kDYStorageFeatureTableScanStateKey = &kDYStorageFeatureTableScanStateKey;
static void *kDYStorageHighlightOverlayAssociationKey = &kDYStorageHighlightOverlayAssociationKey;

static BOOL gDYStorageSettingsHookInstalled = NO;
static BOOL gDYStorageHubHookInstalled = NO;
static BOOL gDYStorageSectionFallbackHookInstalled = NO;
static BOOL gDYStorageSectionHeaderHookInstalled = NO;
static BOOL gDYStorageHubInsertedOnMainSettings = NO;
static BOOL gDYStorageHubPageVisible = NO;
static BOOL gDYStorageOrganizingMainSections = NO;
static BOOL gDYStorageCheckingFallbackHeader = NO;

static void DYStorageRefreshHubController(UIViewController *controller);
static NSArray *DYStorageHubSections(void);

#pragma mark - Runtime-safe model access

static id DYStorageValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *DYStorageStringValue(id object, NSString *key) {
    id value = DYStorageValue(object, key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray *DYStorageArrayValue(id object, NSString *key) {
    id value = DYStorageValue(object, key);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static BOOL DYStorageSetValue(id object, id value, NSString *key) {
    if (!object || key.length == 0) return NO;
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSString *DYStorageNormalizedString(NSString *value) {
    if (value.length == 0) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.lowercaseString.length ? trimmed.lowercaseString : nil;
}

static NSString *DYStorageItemKey(id item) {
    NSString *identifier = DYStorageNormalizedString(DYStorageStringValue(item, @"identifier"));
    if (identifier.length) return [@"identifier:" stringByAppendingString:identifier];
    NSString *title = DYStorageNormalizedString(DYStorageStringValue(item, @"title"));
    return title.length ? [@"title:" stringByAppendingString:title] : nil;
}

#pragma mark - View-controller helpers

static NSArray<UIWindow *> *DYStorageWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *application = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [windows addObjectsFromArray:application.windows];
#pragma clang diagnostic pop
    }
    return windows;
}

static UIWindow *DYStorageKeyWindow(void) {
    for (UIWindow *window in DYStorageWindows()) {
        if (window.isKeyWindow) return window;
    }
    return [DYStorageWindows() firstObject];
}

static UIViewController *DYStorageTopViewController(UIViewController *rootController) {
    UIViewController *controller = rootController ?: DYStorageKeyWindow().rootViewController;
    if (!controller) return nil;

    // Resolve one level at a time so a child of a navigation/tab controller
    // can still have its own presented controller. The hard limit and identity
    // checks prevent malformed private containers from producing an infinite
    // loop on the main thread.
    for (NSUInteger depth = 0; depth < 32; depth++) {
        UIViewController *nextController = nil;
        if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
            nextController = controller.presentedViewController;
        }
        if ([controller isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
            if (!nextController && visible) nextController = visible;
        }
        if ([controller isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
            if (!nextController && selected) nextController = selected;
        }
        if (!nextController || nextController == controller) break;
        controller = nextController;
    }
    return controller;
}

static void DYStorageReloadListsInView(UIView *view, NSInteger depth) {
    if (!view || depth < 0) return;
    if ([view isKindOfClass:[UITableView class]]) {
        [(UITableView *)view reloadData];
        return;
    }
    if ([view isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)view reloadData];
        return;
    }
    for (UIView *subview in view.subviews) {
        DYStorageReloadListsInView(subview, depth - 1);
    }
}

static UITableView *DYStorageFindTableView(UIView *view, NSInteger depth) {
    if (!view || depth < 0) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *tableView = DYStorageFindTableView(subview, depth - 1);
        if (tableView) return tableView;
    }
    return nil;
}

#pragma mark - Discovery rules

static NSArray<NSString *> *DYStorageKnownPluginTitles(void) {
    static NSArray<NSString *> *titles = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // These are root-entry names, not fuzzy keywords. Exact matching keeps
        // ordinary Douyin content and first-party settings out of the organizer.
        titles = @[
            @"DYYY", @"DYKiller", @"AwemeX", @"DouyinHelper",
            @"抖音助手", @"抖音图层", @"抖+", @"抖⁺", @"抖＋",
            @"自动消息", @"aweJ", @"SJJAwemeLoginRepair", @"𝙓𝙐𝙐ᶻ", @"𝙓𝙐𝙐²", @"XUU²", @"XUU", @"Yuki"
        ];
    });
    return titles;
}

static NSString *const kDYStorageConfirmedPluginTitlesKey = @"DYStorageConfirmedPluginTitles";

/// Plug-ins the user explicitly accepted from the discovery list. Keeping them
/// in NSUserDefaults means a confirmed entry survives respring and app updates
/// without shipping it in the hardcoded list.
static NSArray<NSString *> *DYStorageConfirmedPluginTitles(void) {
    id stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kDYStorageConfirmedPluginTitlesKey];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (id title in stored) {
        if ([title isKindOfClass:[NSString class]] && [(NSString *)title length]) {
            [titles addObject:title];
        }
    }
    return titles;
}

static BOOL DYStorageConfirmPluginTitle(NSString *title) {
    NSString *normalized = DYStorageNormalizedString(title);
    if (normalized.length == 0) return NO;
    for (NSString *existing in DYStorageConfirmedPluginTitles()) {
        if ([DYStorageNormalizedString(existing) isEqualToString:normalized]) return NO;
    }
    NSMutableArray<NSString *> *titles = [DYStorageConfirmedPluginTitles() mutableCopy];
    [titles addObject:title];
    [[NSUserDefaults standardUserDefaults] setObject:titles forKey:kDYStorageConfirmedPluginTitlesKey];
    return YES;
}

static NSArray<NSString *> *DYStorageTargetPluginTitles(void) {
    NSMutableArray<NSString *> *titles = [DYStorageKnownPluginTitles() mutableCopy];
    id customTitles = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYStorageTargetPluginTitles"];
    if ([customTitles isKindOfClass:[NSArray class]]) {
        for (id title in (NSArray *)customTitles) {
            if ([title isKindOfClass:[NSString class]] && ((NSString *)title).length) {
                [titles addObject:title];
            }
        }
    }
    for (NSString *confirmed in DYStorageConfirmedPluginTitles()) {
        [titles addObject:confirmed];
    }
    return titles;
}

static BOOL DYStorageTitleIsTargetPlugin(NSString *title) {
    NSString *normalizedTitle = DYStorageNormalizedString(title);
    if (!normalizedTitle.length) return NO;

    for (NSString *candidate in DYStorageTargetPluginTitles()) {
        NSString *normalizedCandidate = DYStorageNormalizedString(candidate);
        if (!normalizedCandidate.length) continue;
        if ([normalizedTitle isEqualToString:normalizedCandidate]) return YES;

        // Some tweaks label the root entry as "DYYY 设置". Accept only a
        // constrained suffix, never a free-form substring match.
        if ([normalizedTitle hasPrefix:normalizedCandidate]) {
            NSString *suffix = [normalizedTitle substringFromIndex:normalizedCandidate.length];
            suffix = [suffix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([suffix isEqualToString:@"设置"] ||
                [suffix isEqualToString:@"setting"] ||
                [suffix isEqualToString:@"settings"]) {
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - Plugin discovery and runtime catalog capture

/// Candidates found on the settings page that look like a third-party root
/// entry but were never confirmed by the user. Nothing here is collected
/// automatically: a two-row system group or a duplicated label must never end
/// up in the organizer because of a heuristic.
static BOOL DYStorageLooksLikeMainSettingsPage(NSArray *sections);
static BOOL DYStorageSectionIsHub(id section);
static BOOL DYStorageSectionIsHubContent(id section);

static NSArray *gDYStorageCandidateSections = nil;

static NSArray *DYStorageCandidateSections(void) {
    return gDYStorageCandidateSections ?: @[];
}

static void DYStorageSetCandidateSections(NSArray *sections) {
    gDYStorageCandidateSections = [sections copy];
}

/// A plug-in root entry is a one-row section whose only row repeats the section
/// header and carries a tap block. Douyin's first-party groups never use that
/// shape for a single row titled after a tweak, so it is a safe thing to offer.
// Groups owned by Douyin itself. A one-row section carrying one of these
// headers is an ordinary settings row, not an unknown plug-in entry.
static BOOL DYStorageHeaderLooksLikeSystemGroup(NSString *header) {
    static NSArray<NSString *> *systemHeaders = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        systemHeaders = @[@"账号", @"账户", @"account", @"general",
                          @"通用", @"设置", @"settings",
                          @"关于", @"about", @"隐私", @"privacy",
                          @"通知", @"notification", @"播放", @"playback",
                          @"存储", @"storage", @"缓存", @"cache",
                          @"清理", @"cleanup", @"反馈", @"feedback",
                          @"帮助", @"help", @"退出", @"logout",
                          @"切换", @"switch", @"青少年", @"teen",
                          @"安全", @"security", @"权限", @"permission",
                          @"实验室", @"lab"];
    });
    for (NSString *candidate in systemHeaders) {
        if ([header isEqualToString:candidate] || [header hasPrefix:candidate]) return YES;
    }
    return NO;
}

/// A browsable one-row section that is not one of the titles DYStorage already
/// owns. Tier one is the exact header/title match every supported plug-in uses
/// today; tier two catches plug-ins that group their entry under a neutral
/// header. Both are suggestions only: the user confirms one before it becomes a
/// collected entry.
static BOOL DYStorageSectionLooksLikePluginEntryCandidate(id section, NSArray *items) {
    if ([items isKindOfClass:[NSArray class]] == NO || items.count != 1) return NO;
    id item = items.firstObject;
    NSString *header = DYStorageNormalizedString(DYStorageStringValue(section, @"sectionHeaderTitle"));
    NSString *itemTitle = DYStorageNormalizedString(DYStorageStringValue(item, @"title"));
    if (itemTitle.length == 0 || header.length > 24) return NO;
    id actionObject = DYStorageValue(item, @"cellTappedBlock");
    if ([NSStringFromClass([actionObject class]) containsString:@"Block"] == NO) return NO;
    if (DYStorageTitleIsTargetPlugin(itemTitle)) return NO;
    if (header.length && [header isEqualToString:itemTitle]) return YES;
    if (header.length == 0) return NO;
    return DYStorageHeaderLooksLikeSystemGroup(header) == NO;
}

/// Set when the user opens a captured plug-in page. The next settings view model
/// that is neither the Douyin root nor the organizer page belongs to that
/// plug-in, so its rows can be indexed for search.
static NSString *gDYStorageCapturePluginTitle = nil;
static NSTimeInterval gDYStorageCaptureDeadline = 0;

static void DYStorageBeginPluginPageCapture(NSString *pluginTitle) {
    gDYStorageCapturePluginTitle = [DYStorageNormalizedString(pluginTitle) copy];
    gDYStorageCaptureDeadline = [[NSDate date] timeIntervalSince1970] + 8.0;
}

static void DYStorageCaptureFeaturesFromSections(NSArray *sections) {
    NSString *plugin = gDYStorageCapturePluginTitle;
    if (plugin.length == 0) return;
    if ([[NSDate date] timeIntervalSince1970] > gDYStorageCaptureDeadline) {
        gDYStorageCapturePluginTitle = nil;
        return;
    }
    if ([sections isKindOfClass:[NSArray class]] == NO || sections.count == 0) return;
    if (DYStorageLooksLikeMainSettingsPage(sections)) return;
    // Going back to the organizer within the capture window would otherwise
    // index DYStorage's own rows as if they belonged to the plug-in.
    for (id section in sections) {
        if (DYStorageSectionIsHub(section) || DYStorageSectionIsHubContent(section)) {
            gDYStorageCapturePluginTitle = nil;
            return;
        }
    }

    NSMutableArray<NSDictionary *> *features = [NSMutableArray array];
    for (id section in sections) {
        NSString *sectionTitle = DYStorageNormalizedString(DYStorageStringValue(section, @"sectionHeaderTitle")) ?: @"";
        NSArray *items = DYStorageArrayValue(section, @"itemArray");
        for (id item in items) {
            if ([item isKindOfClass:[NSObject class]] == NO) continue;
            NSString *title = DYStorageNormalizedString(DYStorageStringValue(item, @"title"));
            if (title.length == 0 || title.length > 40) continue;
            [features addObject:@{ @"section": sectionTitle, @"title": title }];
            if (features.count >= 400) break;
        }
    }
    if (features.count < 3) return;
    DYStorageRuntimeIndexLearn(plugin, features);
    DYStorageLog(@"Indexed %lu features for %@", (unsigned long)features.count, plugin);
    // Keep the marker alive for a short while so a second page of the same
    // plug-in (tabs, detail rows) is merged too. Reopening the organizer or
    // tapping another entry clears it.
    gDYStorageCaptureDeadline = [[NSDate date] timeIntervalSince1970] + 4.0;
}

static BOOL DYStorageItemIsHubEntry(id item);

static BOOL DYStorageSectionIsHubContent(id section) {
    NSString *identifier = DYStorageStringValue(section, @"identifier");
    if ([identifier isEqualToString:kDYStorageHubContentIdentifier]) {
        return YES;
    }
    return [DYStorageStringValue(section, @"sectionHeaderTitle") isEqualToString:kDYStorageHubMarkerTitle];
}

static BOOL DYStorageSectionIsHub(id section) {
    NSString *identifier = DYStorageStringValue(section, @"identifier");
    if ([identifier isEqualToString:kDYStorageHubSectionIdentifier] || DYStorageSectionIsHubContent(section)) {
        return YES;
    }

    // `identifier` is not present in a few older setting-model builds. In that
    // case fall back to a narrowly-scoped title plus our entry identifier.
    if (![DYStorageStringValue(section, @"sectionHeaderTitle") isEqualToString:@"DYStorage"]) return NO;
    for (id item in DYStorageArrayValue(section, @"itemArray")) {
        if (DYStorageItemIsHubEntry(item)) return YES;
    }
    return NO;
}

static BOOL DYStorageItemIsHubEntry(id item) {
    return [DYStorageStringValue(item, @"identifier") isEqualToString:kDYStorageHubEntryIdentifier];
}

static BOOL DYStorageIsXUUAssistantSectionWithItems(id section, NSArray *items) {
    if (items.count != 1) return NO;
    NSString *header = DYStorageNormalizedString(DYStorageStringValue(section, @"sectionHeaderTitle"));
    NSString *itemTitle = DYStorageNormalizedString(DYStorageStringValue(items.firstObject, @"title"));
    BOOL xuuHeader = [header hasPrefix:@"xuu"] ||
                     [header hasPrefix:@"𝙓𝙐𝙐"] ||
                     [header hasPrefix:@"𝓧𝓤𝓤"] ||
                     [header hasPrefix:@"𝕏𝕌𝕌"];
    return xuuHeader && [itemTitle isEqualToString:@"抖音助手"];
}

static NSArray *DYStorageRemoveXUUFromHubSections(NSArray *sections) {
    if (![sections isKindOfClass:[NSArray class]]) return sections;
    NSMutableArray *cleaned = nil;
    for (NSUInteger index = 0; index < sections.count; index++) {
        id section = sections[index];
        if (DYStorageIsXUUAssistantSectionWithItems(section, DYStorageArrayValue(section, @"itemArray"))) {
            if (!cleaned) {
                cleaned = [NSMutableArray arrayWithCapacity:sections.count - 1];
                if (index > 0) [cleaned addObjectsFromArray:[sections subarrayWithRange:NSMakeRange(0, index)]];
            }
            continue;
        }
        if (cleaned) [cleaned addObject:section];
    }
    return cleaned ?: sections;
}

static BOOL DYStorageIsStandalonePluginEntrySection(id section, NSArray *items);

// Douyin periodically renames its first settings group (account/localized).
// A one-row section belonging to a known plugin root is a schema-independent
// signal that this is the root settings page, so the organizer entry does not
// disappear silently when that header changes.
static BOOL DYStorageLooksLikeMainSettingsPage(NSArray *sections) {
    if (![sections isKindOfClass:[NSArray class]]) return NO;

    BOOL sawStandalonePluginSection = NO;

    for (id section in sections) {
        // A hub-content VM is our secondary settings page, never the Douyin
        // root. The root entry itself can safely coexist with an account marker
        // if another tweak has cached a previous return value.
        if (DYStorageSectionIsHubContent(section)) return NO;
        if (DYStorageSectionIsHub(section)) continue;

        if (sawStandalonePluginSection == NO &&
            DYStorageIsStandalonePluginEntrySection(section, DYStorageArrayValue(section, @"itemArray"))) {
            sawStandalonePluginSection = YES;
        }

        NSString *title = DYStorageNormalizedString(DYStorageStringValue(section, @"sectionHeaderTitle"));
        if ([title isEqualToString:@"账号"] || [title hasPrefix:@"账号"] ||
            [title isEqualToString:@"账户"] || [title hasPrefix:@"账户"] ||
            [title isEqualToString:@"account"] || [title isEqualToString:@"general"]) {
            return YES;
        }

        NSString *identifier = DYStorageNormalizedString(DYStorageStringValue(section, @"identifier"));
        if ([identifier containsString:@"account"] && [identifier containsString:@"setting"]) {
            return YES;
        }
    }
    return sawStandalonePluginSection;
}

#pragma mark - Native settings-model construction

static id DYStorageMakeItem(NSString *identifier,
                            NSString *title,
                            NSString *detail,
                            NSString *iconName,
                            void (^action)(void)) {
    Class itemClass = objc_lookUpClass("AWESettingItemModel");
    if (!itemClass) return nil;

    id item = [[itemClass alloc] init];
    if (!item) return nil;

    DYStorageSetValue(item, identifier, @"identifier");
    DYStorageSetValue(item, title, @"title");
    DYStorageSetValue(item, detail ?: @"", @"detail");
    DYStorageSetValue(item, iconName ?: @"", @"svgIconImageName");
    // Older DYYY variants use iconImageName; setting both is harmless when one
    // of the private properties is absent.
    DYStorageSetValue(item, iconName ?: @"", @"iconImageName");
    DYStorageSetValue(item, @0, @"type");
    DYStorageSetValue(item, @26, @"cellType");
    DYStorageSetValue(item, @2, @"colorStyle");
    DYStorageSetValue(item, @YES, @"isEnable");
    if (action) DYStorageSetValue(item, [action copy], @"cellTappedBlock");
    return item;
}

static id DYStorageMakeSection(NSString *identifier,
                               NSString *title,
                               NSArray *items) {
    Class sectionClass = objc_lookUpClass("AWESettingSectionModel");
    if (!sectionClass) return nil;

    id section = [[sectionClass alloc] init];
    if (!section) return nil;

    DYStorageSetValue(section, identifier, @"identifier");
    DYStorageSetValue(section, title, @"sectionHeaderTitle");
    DYStorageSetValue(section, @40, @"sectionHeaderHeight");
    DYStorageSetValue(section, @0, @"type");
    DYStorageSetValue(section, items ?: @[], @"itemArray");
    return section;
}

static id DYStorageCopySectionWithItems(id sourceSection, NSArray *items) {
    if (!sourceSection) return nil;

    id copiedSection = nil;
    @try {
        copiedSection = [sourceSection copy];
    } @catch (__unused NSException *exception) {
        copiedSection = nil;
    }

    if (copiedSection && copiedSection != sourceSection &&
        DYStorageSetValue(copiedSection, items, @"itemArray")) {
        return copiedSection;
    }
    // Do not rebuild an unknown private section class with a partial set of
    // fields. Its layout and click behavior may depend on unexposed state.
    return nil;
}

#pragma mark - Hub page

static void DYStoragePresentController(UIViewController *controller, UIViewController *rootController) {
    if (!controller) return;
    UIViewController *topController = DYStorageTopViewController(rootController);
    if (!topController) return;

    UINavigationController *navigationController = topController.navigationController;
    if (navigationController) {
        [navigationController pushViewController:controller animated:YES];
        return;
    }

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [topController presentViewController:navigation animated:YES completion:nil];
}

static void DYStorageOpenRegistration(DYStorageRegistration *registration) {
    if (!registration) return;
    void (^open)(void) = ^{
        if (registration.action) {
            registration.action();
            return;
        }

        Class controllerClass = NSClassFromString(registration.controllerClassName);
        if (!controllerClass || ![controllerClass isSubclassOfClass:[UIViewController class]]) return;

        UIViewController *controller = [[controllerClass alloc] init];
        if (!controller) return;
        if (controller.title.length == 0) controller.title = registration.title;
        DYStoragePresentController(controller, nil);
    };
    if ([NSThread isMainThread]) open();
    else dispatch_async(dispatch_get_main_queue(), open);
}

#pragma mark - Aggregate search

static BOOL DYStorageDeveloperUIEnabled(void) {
    // Kept off for normal users. Developers can enable the scanner without a
    // rebuild by setting DYStorageDeveloperMode=YES in Aweme's preferences.
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"DYStorageDeveloperMode"];
}

static BOOL DYStorageTitleMatchesCatalogAlias(NSString *title, NSString *alias) {
    NSString *normalizedTitle = DYStorageNormalizedString(title);
    NSString *normalizedAlias = DYStorageNormalizedString(alias);
    if (!normalizedTitle.length || !normalizedAlias.length) return NO;
    if ([normalizedTitle isEqualToString:normalizedAlias]) return YES;
    if (![normalizedTitle hasPrefix:normalizedAlias]) return NO;
    NSString *suffix = [[normalizedTitle substringFromIndex:normalizedAlias.length]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [suffix isEqualToString:@"设置"] ||
           [suffix isEqualToString:@"setting"] ||
           [suffix isEqualToString:@"settings"];
}

static BOOL DYStorageTitleMatchesCatalogEntry(NSString *title, NSDictionary *catalogEntry) {
    if (DYStorageTitleMatchesCatalogAlias(title, catalogEntry[@"plugin"])) return YES;
    for (NSString *alias in catalogEntry[@"aliases"]) {
        if (DYStorageTitleMatchesCatalogAlias(title, alias)) return YES;
    }
    return NO;
}

/// Maps canonical catalog names to the currently installed root entry. The
/// stored action is always the original plug-in callback, so a search result
/// opens the same UI as tapping that plug-in in DYStorage.
static NSDictionary<NSString *, NSDictionary *> *DYStorageInstalledSearchTargets(void) {
    DYStorageManager *manager = [DYStorageManager sharedManager];
    NSArray<NSDictionary *> *catalog = DYStorageSearchCatalogMerged();
    NSMutableDictionary<NSString *, NSDictionary *> *targets = [NSMutableDictionary dictionary];

    for (id item in [manager capturedSettingsItems]) {
        NSString *title = DYStorageStringValue(item, @"title");
        id actionObject = DYStorageValue(item, @"cellTappedBlock");
        if (![NSStringFromClass([actionObject class]) containsString:@"Block"]) continue;

        for (NSDictionary *catalogEntry in catalog) {
            NSString *plugin = catalogEntry[@"plugin"];
            if (plugin.length == 0 || targets[plugin] || !DYStorageTitleMatchesCatalogEntry(title, catalogEntry)) continue;
            DYStorageAction action = [(DYStorageAction)actionObject copy];
            NSString *iconName = DYStorageStringValue(item, @"svgIconImageName") ?:
                                 DYStorageStringValue(item, @"iconImageName") ?: @"ic_search_outlined_20";
            targets[plugin] = @{
                @"action": action,
                @"icon": iconName,
                @"installedTitle": title ?: plugin
            };
            break;
        }
    }

    for (DYStorageRegistration *registration in [manager registeredPlugins]) {
        for (NSDictionary *catalogEntry in catalog) {
            NSString *plugin = catalogEntry[@"plugin"];
            if (plugin.length == 0 || targets[plugin] ||
                !DYStorageTitleMatchesCatalogEntry(registration.title, catalogEntry)) continue;
            DYStorageAction action = ^{
                DYStorageOpenRegistration(registration);
            };
            targets[plugin] = @{
                @"action": [action copy],
                @"icon": @"ic_search_outlined_20",
                @"installedTitle": registration.title ?: plugin
            };
            break;
        }
    }
    return targets;
}

static BOOL DYStorageSearchTextMatches(NSString *query, NSArray<NSString *> *components) {
    for (NSString *component in components) {
        if (![component isKindOfClass:[NSString class]] || component.length == 0) continue;
        if ([component rangeOfString:query
                            options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSUInteger gDYStorageFeatureNavigationGeneration = 0;
static __weak UIViewController *gDYStoragePendingSourceController = nil;
static NSString *gDYStoragePendingFeatureSection = nil;
static NSString *gDYStoragePendingFeatureTitle = nil;
static NSArray<NSString *> *gDYStoragePendingFeatureRoute = nil;
static NSUInteger gDYStoragePendingFeatureRouteIndex = 0;
static __weak UIViewController *gDYStorageLastRouteController = nil;
static NSArray<NSString *> *gDYStoragePendingFloatingRouteCandidates = nil;
static NSUInteger gDYStoragePendingFloatingRouteIndex = 0;
static NSString *gDYStoragePendingPlugin = nil;
static BOOL gDYStorageFeatureScanHasMoreRows = NO;

// A navigation row is invoked at most once per search so a plug-in that keeps
// the same row on the pushed page cannot bounce the user in and out forever.
static NSMutableSet<NSString *> *gDYStorageInvokedItemKeys = nil;
static NSUInteger gDYStorageInvocationCount = 0;

// State for the generic category walk used when a plug-in has no catalog route.
static NSMutableArray<NSString *> *gDYStorageDescentQueue = nil;
static NSMutableSet<NSString *> *gDYStorageDescentVisited = nil;
static __weak UIViewController *gDYStorageDescentPage = nil;
static NSInteger gDYStorageDescentDepth = 0;

static BOOL DYStorageMotionEffectsEnabled(void) {
    return !UIAccessibilityIsReduceMotionEnabled();
}

static void DYStoragePulseHighlightView(UIView *view) {
    if (!view || !view.window) return;
    UIView *previousOverlay = objc_getAssociatedObject(view, kDYStorageHighlightOverlayAssociationKey);
    [previousOverlay.layer removeAllAnimations];
    [previousOverlay removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:view.bounds];
    overlay.userInteractionEnabled = NO;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor.systemYellowColor colorWithAlphaComponent:0.28];
    overlay.layer.cornerRadius = MIN(10.0, view.layer.cornerRadius);
    overlay.alpha = 0;
    [view addSubview:overlay];
    objc_setAssociatedObject(view,
                             kDYStorageHighlightOverlayAssociationKey,
                             overlay,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    void (^removeOverlay)(void) = ^{
        if (objc_getAssociatedObject(view, kDYStorageHighlightOverlayAssociationKey) == overlay) {
            objc_setAssociatedObject(view,
                                     kDYStorageHighlightOverlayAssociationKey,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [overlay removeFromSuperview];
    };
    if (!DYStorageMotionEffectsEnabled()) {
        overlay.alpha = 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), removeOverlay);
        return;
    }

    [UIView animateWithDuration:0.12
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ overlay.alpha = 1; }
                     completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.34
                              delay:0.06
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ overlay.alpha = 0; }
                         completion:^(__unused BOOL completed) { removeOverlay(); }];
    }];
}

static void DYStorageScrollToFeatureView(UIView *view) {
    if (!view) return;
    UIScrollView *scrollView = nil;
    BOOL needsScroll = NO;
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[UIScrollView class]]) {
            scrollView = (UIScrollView *)ancestor;
            break;
        }
    }
    if (scrollView) {
        CGRect rect = [view convertRect:view.bounds toView:scrollView];
        CGRect visibleBounds = CGRectInset(scrollView.bounds, 8, 8);
        needsScroll = !CGRectContainsRect(visibleBounds, rect);
        if (needsScroll) {
            [scrollView scrollRectToVisible:CGRectInset(rect, -12, -18)
                                    animated:DYStorageMotionEffectsEnabled()];
        }
    }
    __weak UIView *weakView = view;
    NSTimeInterval delay = needsScroll && DYStorageMotionEffectsEnabled() ? 0.20 : 0.04;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DYStoragePulseHighlightView(weakView);
    });
}

static NSString *DYStorageNormalizedFeatureText(NSString *text) {
    NSString *normalized = DYStorageNormalizedString(text);
    if (!normalized.length) return nil;
    NSCharacterSet *prefixes = [NSCharacterSet characterSetWithCharactersInString:@"•·●◦▪▫・- "];
    return [normalized stringByTrimmingCharactersInSet:prefixes];
}

static NSString *DYStorageVisibleTextForView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text;
    if ([view isKindOfClass:[UIButton class]]) {
        return [(UIButton *)view titleForState:UIControlStateNormal] ?: view.accessibilityLabel;
    }
    if ([view isKindOfClass:[UITextField class]]) return ((UITextField *)view).text;
    return view.accessibilityLabel;
}

static UIView *DYStorageFindFeatureTextView(UIView *view,
                                            UIView *ignoredRoot,
                                            NSString *normalizedTitle,
                                            NSInteger depth) {
    if (!view || depth < 0 || view.hidden || view.alpha < 0.01) return nil;
    if (ignoredRoot && (view == ignoredRoot || [view isDescendantOfView:ignoredRoot])) return nil;
    NSString *text = DYStorageNormalizedFeatureText(DYStorageVisibleTextForView(view));
    if (text.length && [text isEqualToString:normalizedTitle]) return view;
    for (UIView *subview in [view.subviews reverseObjectEnumerator]) {
        UIView *match = DYStorageFindFeatureTextView(subview, ignoredRoot, normalizedTitle, depth - 1);
        if (match) return match;
    }
    return nil;
}

static BOOL DYStorageViewContainsDirectSettingControl(UIView *view, NSInteger depth) {
    if (!view || depth < 0) return NO;
    if ([view isKindOfClass:[UISwitch class]] ||
        [view isKindOfClass:[UISlider class]] ||
        [view isKindOfClass:[UISegmentedControl class]] ||
        [view isKindOfClass:[UIStepper class]] ||
        [view isKindOfClass:[UITextField class]] ||
        [view isKindOfClass:[UITextView class]] ||
        [view isKindOfClass:[UIPickerView class]] ||
        [view isKindOfClass:[UIDatePicker class]]) return YES;
    for (UIView *subview in view.subviews) {
        if (DYStorageViewContainsDirectSettingControl(subview, depth - 1)) return YES;
    }
    return NO;
}

static BOOL DYStorageCellShowsNavigationCue(UITableViewCell *cell, NSString *normalizedTitle) {
    if (!cell) return NO;
    if (cell.accessoryType == UITableViewCellAccessoryDisclosureIndicator) return YES;
    if (DYStorageViewContainsDirectSettingControl(cell.contentView, 10) ||
        DYStorageViewContainsDirectSettingControl(cell.accessoryView, 6)) return NO;
    if ([normalizedTitle containsString:@"点击此栏"] ||
        [normalizedTitle containsString:@"点此栏"] ||
        [normalizedTitle containsString:@"打开配置"]) return YES;

    CGFloat contentWidth = CGRectGetWidth(cell.contentView.bounds);
    if (contentWidth <= 0) contentWidth = CGRectGetWidth(cell.bounds);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:cell.contentView.subviews ?: @[]];
    if (cell.accessoryView) [stack addObject:cell.accessoryView];
    for (NSUInteger index = 0; index < stack.count && index < 80; index++) {
        UIView *candidate = stack[index];
        if (candidate.hidden || candidate.alpha < 0.01) continue;
        NSString *candidateText = DYStorageNormalizedFeatureText(DYStorageVisibleTextForView(candidate));
        if ([candidateText isEqualToString:@">"] || [candidateText isEqualToString:@"›"] ||
            [candidateText isEqualToString:@"〉"] || [candidateText isEqualToString:@"❯"]) return YES;
        if ([candidate isKindOfClass:[UIImageView class]] || [candidate isKindOfClass:[UIButton class]]) {
            CGRect frame = [candidate convertRect:candidate.bounds toView:cell.contentView];
            BOOL compact = CGRectGetWidth(frame) <= 48 && CGRectGetHeight(frame) <= 48;
            if (compact && CGRectGetMidX(frame) >= contentWidth * 0.72) return YES;
        }
        if (stack.count < 80) [stack addObjectsFromArray:candidate.subviews];
    }
    return NO;
}

static void DYStorageActivateOrHighlightTableRow(UITableView *tableView,
                                                  NSIndexPath *indexPath,
                                                  UITableViewCell *candidateCell,
                                                  NSString *normalizedTitle) {
    if (!tableView || !indexPath) return;
    id<UITableViewDelegate> delegate = tableView.delegate;
    UITableViewCell *resolvedCell = candidateCell ?: [tableView cellForRowAtIndexPath:indexPath];
    if (resolvedCell && CGRectGetWidth(resolvedCell.bounds) <= 0 && CGRectGetWidth(tableView.bounds) > 0) {
        resolvedCell.bounds = CGRectMake(0, 0, CGRectGetWidth(tableView.bounds), 44);
        [resolvedCell layoutIfNeeded];
    }
    if (DYStorageCellShowsNavigationCue(resolvedCell, normalizedTitle) &&
        [delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        @try {
            [delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
        } @catch (__unused NSException *exception) {
        }
        return;
    }

    BOOL alreadyVisible = [[tableView indexPathsForVisibleRows] containsObject:indexPath];
    BOOL animated = !alreadyVisible && DYStorageMotionEffectsEnabled();
    @try {
        if (!alreadyVisible) {
            [tableView scrollToRowAtIndexPath:indexPath
                              atScrollPosition:UITableViewScrollPositionMiddle
                                      animated:animated];
        }
    } @catch (__unused NSException *exception) {
        return;
    }

    __weak UITableView *weakTableView = tableView;
    NSTimeInterval delay = animated ? 0.22 : 0.04;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UITableView *strongTableView = weakTableView;
        UITableViewCell *cell = [strongTableView cellForRowAtIndexPath:indexPath];
        if (!cell) return;
        DYStoragePulseHighlightView(cell.contentView ?: cell);
    });
}

static BOOL DYStorageLocateFeatureInTableViews(UIView *view,
                                               UIView *ignoredRoot,
                                               NSString *normalizedTitle,
                                               NSInteger depth) {
    if (!view || depth < 0 || view.hidden || view.alpha < 0.01) return NO;
    if (ignoredRoot && (view == ignoredRoot || [view isDescendantOfView:ignoredRoot])) return NO;

    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)view;
        id<UITableViewDataSource> dataSource = tableView.dataSource;
        NSInteger sectionCount = 0;
        @try {
            sectionCount = [dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]
                ? [dataSource numberOfSectionsInTableView:tableView]
                : (dataSource ? 1 : 0);
        } @catch (__unused NSException *exception) {
            sectionCount = 0;
        }
        sectionCount = MAX(0, MIN(sectionCount, 80));
        NSMutableArray<NSNumber *> *rowCounts = [NSMutableArray arrayWithCapacity:(NSUInteger)sectionCount];
        NSInteger totalRows = 0;
        for (NSInteger section = 0; section < sectionCount && totalRows < 400; section++) {
            NSInteger rowCount = 0;
            @try {
                rowCount = [dataSource tableView:tableView numberOfRowsInSection:section];
            } @catch (__unused NSException *exception) {
                rowCount = 0;
            }
            rowCount = MAX(0, MIN(rowCount, 400 - totalRows));
            [rowCounts addObject:@(rowCount)];
            totalRows += rowCount;
        }

        // A missing feature used to rebuild hundreds of off-screen cells on
        // every scheduled retry. Cache a bounded scan cursor for each
        // navigation generation/table shape so a failed lookup cannot freeze
        // the main thread on a large plug-in page.
        NSDictionary *previousState = objc_getAssociatedObject(tableView, kDYStorageFeatureTableScanStateKey);
        BOOL sameScan = totalRows > 0 &&
            [previousState[@"generation"] unsignedIntegerValue] == gDYStorageFeatureNavigationGeneration &&
            [previousState[@"rowCounts"] isEqual:rowCounts] &&
            [previousState[@"contentHeight"] doubleValue] == tableView.contentSize.height;
        NSInteger startRow = sameScan ? [previousState[@"nextRow"] integerValue] : 0;
        startRow = MAX(0, MIN(startRow, totalRows));
        // Construct private off-screen cells in bounded batches. Scheduled
        // retries continue at nextRow instead of blocking one main-thread turn
        // with every row in a large plug-in page.
        NSInteger endRow = MIN(totalRows, startRow + 80);
        if (startRow < endRow) {
            NSInteger flatRow = 0;
            for (NSUInteger section = 0; section < rowCounts.count && flatRow < endRow; section++) {
                NSInteger rowCount = rowCounts[section].integerValue;
                for (NSInteger row = 0; row < rowCount && flatRow < endRow; row++, flatRow++) {
                    if (flatRow < startRow) continue;
                    @autoreleasepool {
                        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:(NSInteger)section];
                        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                        if (!cell && [dataSource respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) {
                            @try {
                                cell = [dataSource tableView:tableView cellForRowAtIndexPath:indexPath];
                            } @catch (__unused NSException *exception) {
                                cell = nil;
                            }
                        }
                        if (!cell || !DYStorageFindFeatureTextView(cell, nil, normalizedTitle, 10)) continue;
                        DYStorageActivateOrHighlightTableRow(tableView, indexPath, cell, normalizedTitle);
                        return YES;
                    }
                }
            }
        }
        if (endRow < totalRows) gDYStorageFeatureScanHasMoreRows = YES;
        objc_setAssociatedObject(tableView,
                                 kDYStorageFeatureTableScanStateKey,
                                 @{ @"generation": @(gDYStorageFeatureNavigationGeneration),
                                    @"rowCounts": [rowCounts copy],
                                    @"contentHeight": @(tableView.contentSize.height),
                                    @"nextRow": @(endRow) },
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *subview in [view.subviews reverseObjectEnumerator]) {
        if (DYStorageLocateFeatureInTableViews(subview, ignoredRoot, normalizedTitle, depth - 1)) return YES;
    }
    return NO;
}

static BOOL DYStorageActivateFloatingRouteInTableViews(UIView *view,
                                                        UIView *ignoredRoot,
                                                        NSString *normalizedTitle,
                                                        NSInteger depth) {
    if (!view || depth < 0 || view.hidden || view.alpha < 0.01) return NO;
    if (ignoredRoot && (view == ignoredRoot || [view isDescendantOfView:ignoredRoot])) return NO;

    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)view;
        id<UITableViewDataSource> dataSource = tableView.dataSource;
        id<UITableViewDelegate> delegate = tableView.delegate;
        NSInteger sectionCount = 0;
        @try {
            sectionCount = [dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]
                ? [dataSource numberOfSectionsInTableView:tableView]
                : (dataSource ? 1 : 0);
        } @catch (__unused NSException *exception) {
            sectionCount = 0;
        }
        sectionCount = MAX(0, MIN(sectionCount, 40));

        NSInteger inspectedRows = 0;
        for (NSInteger section = 0; section < sectionCount && inspectedRows < 80; section++) {
            NSInteger rowCount = 0;
            @try {
                rowCount = [dataSource tableView:tableView numberOfRowsInSection:section];
            } @catch (__unused NSException *exception) {
                rowCount = 0;
            }
            rowCount = MAX(0, MIN(rowCount, 80 - inspectedRows));
            for (NSInteger row = 0; row < rowCount; row++, inspectedRows++) {
                @autoreleasepool {
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
                    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                    if (!cell && [dataSource respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) {
                        @try {
                            cell = [dataSource tableView:tableView cellForRowAtIndexPath:indexPath];
                        } @catch (__unused NSException *exception) {
                            cell = nil;
                        }
                    }
                    if (!cell || !DYStorageFindFeatureTextView(cell, nil, normalizedTitle, 10)) continue;
                    if (![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;

                    if (!tableView.window) return NO;
                    @try {
                        [tableView scrollToRowAtIndexPath:indexPath
                                         atScrollPosition:UITableViewScrollPositionMiddle
                                                 animated:NO];
                        objc_setAssociatedObject(tableView,
                                                 kDYStorageFeatureTableScanStateKey,
                                                 nil,
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        [delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
                        return YES;
                    } @catch (__unused NSException *exception) {
                        return NO;
                    }
                }
            }
        }
    }

    for (UIView *subview in [view.subviews reverseObjectEnumerator]) {
        if (DYStorageActivateFloatingRouteInTableViews(subview,
                                                       ignoredRoot,
                                                       normalizedTitle,
                                                       depth - 1)) return YES;
    }
    return NO;
}

static BOOL DYStorageWindowContainsFloatingPlugin(UIWindow *window,
                                                   UIView *ignoredRoot,
                                                   NSString *normalizedPlugin) {
    UIView *marker = DYStorageFindFeatureTextView(window, ignoredRoot, normalizedPlugin, 24);
    if (!marker || marker.window != window) return NO;
    CGRect markerFrame = [marker convertRect:marker.bounds toView:window];
    return !CGRectIsEmpty(markerFrame) && CGRectIntersectsRect(window.bounds, markerFrame);
}

static BOOL DYStorageFloatingPluginPanelIsVisible(UIViewController *sourceController,
                                                   NSString *plugin) {
    if (!sourceController || !sourceController.viewIfLoaded.window || !plugin.length) return NO;
    NSString *normalizedPlugin = DYStorageNormalizedFeatureText(plugin);
    if (!normalizedPlugin.length) return NO;
    UIWindow *sourceWindow = sourceController.viewIfLoaded.window;
    UIView *ignoredRoot = DYStorageFindTableView(sourceController.viewIfLoaded, 8) ?: sourceController.viewIfLoaded;
    for (UIWindow *window in DYStorageWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        if (@available(iOS 13.0, *)) {
            if (sourceWindow.windowScene && window.windowScene != sourceWindow.windowScene) continue;
        }
        if (DYStorageWindowContainsFloatingPlugin(window, ignoredRoot, normalizedPlugin)) return YES;
    }
    return NO;
}

static BOOL DYStorageActivateFloatingRouteInVisibleWindows(UIViewController *sourceController,
                                                            NSString *plugin,
                                                            NSString *routeTitle) {
    if (!DYStorageFloatingPluginPanelIsVisible(sourceController, plugin)) return NO;
    NSString *normalizedTitle = DYStorageNormalizedFeatureText(routeTitle);
    if (!normalizedTitle.length) return NO;
    NSString *normalizedPlugin = DYStorageNormalizedFeatureText(plugin);
    UIWindow *sourceWindow = sourceController.viewIfLoaded.window;
    UIView *ignoredRoot = DYStorageFindTableView(sourceController.viewIfLoaded, 8) ?: sourceController.viewIfLoaded;
    NSArray<UIWindow *> *windows = [DYStorageWindows() sortedArrayUsingComparator:^NSComparisonResult(UIWindow *left,
                                                                                                       UIWindow *right) {
        if (left.windowLevel > right.windowLevel) return NSOrderedAscending;
        if (left.windowLevel < right.windowLevel) return NSOrderedDescending;
        if (left.isKeyWindow != right.isKeyWindow) return left.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        if (@available(iOS 13.0, *)) {
            if (sourceWindow.windowScene && window.windowScene != sourceWindow.windowScene) continue;
        }
        if (!DYStorageWindowContainsFloatingPlugin(window,
                                                    ignoredRoot,
                                                    normalizedPlugin)) continue;
        if (DYStorageActivateFloatingRouteInTableViews(window,
                                                       ignoredRoot,
                                                       normalizedTitle,
                                                       24)) return YES;
    }
    return NO;
}

static BOOL DYStorageLocateFeatureInVisibleWindows(UIViewController *sourceController,
                                                   NSString *plugin,
                                                   NSString *title,
                                                   BOOL restrictToFloatingPanel) {
    if (!sourceController) return NO;
    NSString *normalizedTitle = DYStorageNormalizedFeatureText(title);
    if (!normalizedTitle.length) return NO;
    NSString *normalizedPlugin = DYStorageNormalizedFeatureText(plugin);
    UIWindow *sourceWindow = sourceController.viewIfLoaded.window;
    // Ignore the organizer's result table itself, but not the whole source
    // controller: XUU/AwemeX may attach their floating panel directly above
    // that same controller instead of presenting a new controller/window.
    UIView *ignoredRoot = DYStorageFindTableView(sourceController.viewIfLoaded, 8) ?: sourceController.viewIfLoaded;
    NSArray<UIWindow *> *windows = [DYStorageWindows() sortedArrayUsingComparator:^NSComparisonResult(UIWindow *left,
                                                                                                       UIWindow *right) {
        if (left.windowLevel > right.windowLevel) return NSOrderedAscending;
        if (left.windowLevel < right.windowLevel) return NSOrderedDescending;
        if (left.isKeyWindow != right.isKeyWindow) return left.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        if (restrictToFloatingPanel) {
            if (@available(iOS 13.0, *)) {
                if (sourceWindow.windowScene && window.windowScene != sourceWindow.windowScene) continue;
            }
        }
        if (restrictToFloatingPanel &&
            !DYStorageWindowContainsFloatingPlugin(window,
                                                    ignoredRoot,
                                                    normalizedPlugin)) continue;
        UIView *match = DYStorageFindFeatureTextView(window, ignoredRoot, normalizedTitle, 24);
        if (match) {
            UITableViewCell *cell = nil;
            UITableView *tableView = nil;
            for (UIView *ancestor = match; ancestor; ancestor = ancestor.superview) {
                if (!cell && [ancestor isKindOfClass:[UITableViewCell class]]) cell = (UITableViewCell *)ancestor;
                if ([ancestor isKindOfClass:[UITableView class]]) {
                    tableView = (UITableView *)ancestor;
                    break;
                }
            }
            NSIndexPath *indexPath = cell && tableView ? [tableView indexPathForCell:cell] : nil;
            if (indexPath) DYStorageActivateOrHighlightTableRow(tableView, indexPath, cell, normalizedTitle);
            else DYStorageScrollToFeatureView(match);
            return YES;
        }
        // UITableView keeps only visible cells attached. Ask the plug-in's data
        // source for lightweight cells so an off-screen XUU/AwemeX row can be
        // found and scrolled into view without guessing its position.
        if (DYStorageLocateFeatureInTableViews(window, ignoredRoot, normalizedTitle, 24)) return YES;
    }
    return NO;
}

static BOOL DYStorageLocateFeatureInSettingsController(UIViewController *controller,
                                                        NSString *sectionTitle,
                                                        NSString *featureTitle) {
    if (!controller || objc_getAssociatedObject(controller, kDYStorageViewModelAssociationKey)) return NO;
    id viewModel = DYStorageValue(controller, @"viewModel");
    NSArray *sections = DYStorageArrayValue(viewModel, @"sectionDataArray");
    if (sections.count == 0) return NO;

    NSString *normalizedSection = DYStorageNormalizedString(sectionTitle);
    NSString *normalizedFeature = DYStorageNormalizedString(featureTitle);
    NSInteger matchedSection = NSNotFound;
    NSInteger matchedRow = NSNotFound;
    id matchedItem = nil;

    // Prefer the scanned section path; fall back to an exact title match when
    // a plug-in renamed or regrouped the setting in a later release.
    for (NSInteger pass = 0; pass < 2 && !matchedItem; pass++) {
        for (NSUInteger sectionIndex = 0; sectionIndex < sections.count && !matchedItem; sectionIndex++) {
            id section = sections[sectionIndex];
            NSString *candidateSection = DYStorageNormalizedString(DYStorageStringValue(section, @"sectionHeaderTitle"));
            if (pass == 0 && normalizedSection.length && ![candidateSection isEqualToString:normalizedSection]) continue;
            NSArray *items = DYStorageArrayValue(section, @"itemArray");
            for (NSUInteger rowIndex = 0; rowIndex < items.count; rowIndex++) {
                id item = items[rowIndex];
                if (![DYStorageNormalizedString(DYStorageStringValue(item, @"title")) isEqualToString:normalizedFeature]) continue;
                matchedSection = (NSInteger)sectionIndex;
                matchedRow = (NSInteger)rowIndex;
                matchedItem = item;
                break;
            }
        }
    }
    if (!matchedItem) return NO;

    NSNumber *cellType = DYStorageValue(matchedItem, @"cellType");
    id actionObject = DYStorageValue(matchedItem, @"cellTappedBlock");
    if ([cellType isKindOfClass:[NSNumber class]] && cellType.integerValue == 26 &&
        [NSStringFromClass([actionObject class]) containsString:@"Block"]) {
        // Cell type 26 is the settings framework's tappable navigation/action
        // row. Invoking it only opens the next page, so the pending search has
        // to stay alive and let the retry loop look for the requested row on
        // that page. Returning YES here used to stop the search one level early,
        // which is why a hit inside a category never reached its own row.
        NSString *invocationKey = [NSString stringWithFormat:@"%@|%@",
                                   normalizedSection ?: @"", normalizedFeature ?: @""];
        if (gDYStorageInvokedItemKeys == nil) gDYStorageInvokedItemKeys = [NSMutableSet set];
        if ([gDYStorageInvokedItemKeys containsObject:invocationKey]) return YES;
        if (gDYStorageInvocationCount >= 10) return YES;
        [gDYStorageInvokedItemKeys addObject:invocationKey];
        gDYStorageInvocationCount += 1;

        DYStorageAction action = [(DYStorageAction)actionObject copy];
        @try {
            action();
        } @catch (__unused NSException *exception) {
            return NO;
        }
        return NO;
    }

    UITableView *tableView = DYStorageFindTableView(controller.viewIfLoaded, 8);
    if (!tableView || matchedSection == NSNotFound || matchedRow == NSNotFound) return YES;
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:matchedRow inSection:matchedSection];
    @try {
        BOOL alreadyVisible = [[tableView indexPathsForVisibleRows] containsObject:indexPath];
        BOOL animated = !alreadyVisible && DYStorageMotionEffectsEnabled();
        if (!alreadyVisible) {
            [tableView scrollToRowAtIndexPath:indexPath
                              atScrollPosition:UITableViewScrollPositionMiddle
                                      animated:animated];
        }
        __weak UITableView *weakTableView = tableView;
        NSTimeInterval delay = animated ? 0.22 : 0.04;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UITableView *strongTableView = weakTableView;
            if (!strongTableView.window) return;
            UITableViewCell *cell = [strongTableView cellForRowAtIndexPath:indexPath];
            if (!DYStorageFindFeatureTextView(cell, nil, normalizedFeature, 10)) return;
            DYStoragePulseHighlightView(cell.contentView ?: cell);
        });
    } @catch (__unused NSException *exception) {
        // The private table model can differ between app versions. The feature
        // was still resolved, so leave the user on the correct plug-in page.
    }
    return YES;
}

static UITextField *DYStorageFindSettingsSearchField(UIView *view, NSInteger depth) {
    if (!view || depth < 0 || view.hidden || view.alpha < 0.01) return nil;
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        NSString *accessibility = DYStorageNormalizedString(field.accessibilityLabel);
        NSString *placeholder = DYStorageNormalizedString(field.placeholder);
        // Douyin's own field is labelled "settings search"; most third-party
        // plug-ins only label theirs "search". Accept both, otherwise the
        // fallback below never fires outside the first-party page.
        BOOL settingsSearch = [accessibility containsString:@"设置搜索"] ||
                              [placeholder containsString:@"搜索设置"] ||
                              [accessibility containsString:@"搜索"] ||
                              [placeholder containsString:@"搜索"] ||
                              [accessibility containsString:@"search"] ||
                              [placeholder containsString:@"search"];
        if (settingsSearch) return field;
    }
    for (UIView *subview in view.subviews) {
        UITextField *field = DYStorageFindSettingsSearchField(subview, depth - 1);
        if (field) return field;
    }
    return nil;
}

static BOOL DYStoragePrepareNativePluginSearch(UIViewController *controller, NSString *featureTitle) {
    if (!controller || !featureTitle.length ||
        objc_getAssociatedObject(controller, kDYStorageViewModelAssociationKey)) return NO;
    UITextField *searchField = DYStorageFindSettingsSearchField(controller.viewIfLoaded, 16);
    if (!searchField) return NO;
    if (![searchField.text isEqualToString:featureTitle]) {
        searchField.text = featureTitle;
        [searchField sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    return YES;
}

static NSArray<NSString *> *DYStorageNavigationRouteForFeature(NSString *plugin,
                                                                NSDictionary *feature) {
    id explicitRoute = feature[@"route"];
    if ([explicitRoute isKindOfClass:[NSString class]] && [explicitRoute length]) {
        return @[ explicitRoute ];
    }
    if ([explicitRoute isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *route = [NSMutableArray array];
        for (id component in (NSArray *)explicitRoute) {
            if ([component isKindOfClass:[NSString class]] && [component length]) {
                [route addObject:component];
            }
        }
        if (route.count) return route;
    }

    // The installed DYYY build constructs all search models while remaining on
    // its root controller, so the scanner cannot observe the pushed page in
    // pagePath. These section-to-page relationships are the real root menu
    // callbacks used by DYYY and let DYStorage enter the correct second level
    // before locating a switch, slider, or action row.
    if (![plugin isEqualToString:@"DYYY"]) return @[];
    NSString *section = feature[@"section"];
    if (!section.length || [section isEqualToString:@"功能"] ||
        [section isEqualToString:@"清理"] || [section isEqualToString:@"备份"] ||
        [section isEqualToString:@"关于"]) {
        return @[];
    }

    static NSDictionary<NSString *, NSString *> *pageBySection = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];
        NSDictionary<NSString *, NSArray<NSString *> *> *sectionsByPage = @{
            @"基本设置": @[ @"外观设置", @"视频播放", @"播放控制", @"进度显示",
                            @"弹幕", @"属地标签", @"直播", @"画质帧率", @"杂项设置",
                            @"过滤与屏蔽", @"推荐过滤", @"隐私", @"二次确认", @"广告与弹窗" ],
            @"界面设置": @[ @"首页布局", @"透明度设置", @"缩放与大小", @"标题自定义", @"图标自定义" ],
            @"隐藏设置": @[ @"主界面元素", @"视频播放界面", @"侧边栏元素", @"消息页与我的页",
                            @"提示与位置信息", @"直播间界面", @"隐藏面板功能", @"隐藏长按评论功能" ],
            @"顶栏移除": @[ @"顶栏选项" ],
            @"增强设置": @[ @"长按面板设置", @"媒体保存", @"交互增强", @"账号与登录", @"ABTest" ],
            @"悬浮按钮": @[ @"快捷倍速", @"一键清屏" ]
        };
        [sectionsByPage enumerateKeysAndObjectsUsingBlock:^(NSString *page,
                                                            NSArray<NSString *> *sections,
                                                            __unused BOOL *stop) {
            for (NSString *name in sections) mapping[name] = page;
        }];
        pageBySection = [mapping copy];
    });
    NSString *page = pageBySection[section];
    return page.length ? @[ page ] : @[];
}

static NSArray<NSString *> *DYStorageFloatingRouteCandidatesForFeature(NSString *plugin,
                                                                        NSString *featureTitle) {
    if ([plugin isEqualToString:@"抖音助手"]) {
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *title = DYStorageNormalizedFeatureText(featureTitle);
        if ([title hasPrefix:@"隐藏"]) {
            [candidates addObject:@"隐藏设置"];
        } else if ([title hasPrefix:@"移除"]) {
            [candidates addObject:@"移除顶栏"];
        } else if ([title hasPrefix:@"设置"] || [title hasPrefix:@"时间"] ||
                   [title hasPrefix:@"时长"] || [title hasPrefix:@"显示"] ||
                   [title hasPrefix:@"作品日期"]) {
            [candidates addObject:@"界面设置"];
        } else {
            [candidates addObject:@"增强设置"];
        }
        for (NSString *fallback in @[ @"增强设置", @"界面设置", @"隐藏设置", @"移除顶栏" ]) {
            if (![candidates containsObject:fallback]) [candidates addObject:fallback];
        }
        return candidates;
    }
    if ([plugin isEqualToString:@"抖音图层"]) {
        // AwemeX's floating root contains four custom category rows. Prefer the
        // category implied by the scanned title, then keep the others as
        // fallbacks for renamed/regrouped options in later plug-in releases.
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *title = DYStorageNormalizedFeatureText(featureTitle);
        if ([title containsString:@"透明度"]) {
            [candidates addObject:@"透明度"];
        } else if ([title hasPrefix:@"移除"]) {
            [candidates addObject:@"移除项"];
        } else if ([title hasPrefix:@"隐藏"]) {
            [candidates addObject:@"隐藏项"];
        } else {
            [candidates addObject:@"增强项"];
        }
        for (NSString *fallback in @[ @"增强项", @"透明度", @"移除项", @"隐藏项" ]) {
            if (![candidates containsObject:fallback]) [candidates addObject:fallback];
        }
        return candidates;
    }
    return @[];
}

static BOOL DYStorageInvokeSettingsNavigationItem(UIViewController *controller,
                                                   NSString *title) {
    if (!controller || !title.length ||
        objc_getAssociatedObject(controller, kDYStorageViewModelAssociationKey)) return NO;
    NSString *normalizedTitle = DYStorageNormalizedString(title);
    id viewModel = DYStorageValue(controller, @"viewModel");
    for (id section in DYStorageArrayValue(viewModel, @"sectionDataArray")) {
        for (id item in DYStorageArrayValue(section, @"itemArray")) {
            if (![DYStorageNormalizedString(DYStorageStringValue(item, @"title"))
                    isEqualToString:normalizedTitle]) continue;
            NSNumber *cellType = DYStorageValue(item, @"cellType");
            id actionObject = DYStorageValue(item, @"cellTappedBlock");
            BOOL navigationCell = ![cellType isKindOfClass:[NSNumber class]] ||
                cellType.integerValue == 26;
            if (!navigationCell || ![NSStringFromClass([actionObject class]) containsString:@"Block"]) continue;
            DYStorageAction action = [(DYStorageAction)actionObject copy];
            @try {
                action();
                return YES;
            } @catch (__unused NSException *exception) {
                return NO;
            }
        }
    }
    return NO;
}

static BOOL DYStorageFeatureRouteIsReady(UIViewController *controller,
                                         UIViewController *sourceController) {
    NSArray<NSString *> *route = gDYStoragePendingFeatureRoute;
    if (route.count == 0) return YES;
    if (!controller || controller == sourceController) return NO;

    while (gDYStoragePendingFeatureRouteIndex < route.count) {
        NSString *routeTitle = route[gDYStoragePendingFeatureRouteIndex];
        NSString *controllerTitle = DYStorageNormalizedString(controller.title ?: controller.navigationItem.title);
        if ([controllerTitle isEqualToString:DYStorageNormalizedString(routeTitle)]) {
            gDYStoragePendingFeatureRouteIndex += 1;
            gDYStorageLastRouteController = nil;
            continue;
        }
        if (controller == gDYStorageLastRouteController) return NO;
        if (!DYStorageInvokeSettingsNavigationItem(controller, routeTitle)) return NO;
        gDYStoragePendingFeatureRouteIndex += 1;
        gDYStorageLastRouteController = controller;
        return NO;
    }

    // A route action normally pushes/presents the destination asynchronously.
    // Do not search the root model during that transition: it may contain a
    // prebuilt global index and would falsely report the feature as resolved.
    return controller != gDYStorageLastRouteController;
}

static void DYStorageClearPendingFeatureNavigation(NSUInteger generation) {
    if (generation != gDYStorageFeatureNavigationGeneration) return;
    ++gDYStorageFeatureNavigationGeneration;
    gDYStoragePendingSourceController = nil;
    gDYStoragePendingFeatureSection = nil;
    gDYStoragePendingFeatureTitle = nil;
    gDYStoragePendingFeatureRoute = nil;
    gDYStoragePendingFeatureRouteIndex = 0;
    gDYStorageLastRouteController = nil;
    gDYStoragePendingFloatingRouteCandidates = nil;
    gDYStoragePendingFloatingRouteIndex = 0;
    gDYStoragePendingPlugin = nil;
}

static BOOL DYStorageResolveFeatureInController(UIViewController *controller,
                                                UIViewController *sourceController,
                                                NSString *section,
                                                NSString *title) {
    if (!controller || controller == sourceController) return NO;
    if (!DYStorageFeatureRouteIsReady(controller, sourceController)) return NO;
    if (DYStorageLocateFeatureInSettingsController(controller, section, title)) return YES;
    // DYYY builds its real search entries from the original item models. Feed
    // the requested title into that native search first; a following pass can
    // then invoke/locate the exact original item instead of a static proxy.
    DYStoragePrepareNativePluginSearch(controller, title);
    return NO;
}

/// Rows that only push a child page inside a plug-in. Used when the static
/// catalog has no route for a plug-in, which is the normal case outside DYYY.
static NSArray<NSString *> *DYStorageNavigationCandidateTitles(UIViewController *controller,
                                                                NSString *featureTitle) {
    if (controller == nil || featureTitle.length == 0) return @[];
    if (objc_getAssociatedObject(controller, kDYStorageViewModelAssociationKey)) return @[];
    NSString *normalizedFeature = DYStorageNormalizedString(featureTitle);
    id viewModel = DYStorageValue(controller, @"viewModel");
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (id section in DYStorageArrayValue(viewModel, @"sectionDataArray")) {
        for (id item in DYStorageArrayValue(section, @"itemArray")) {
            NSNumber *cellType = DYStorageValue(item, @"cellType");
            if ([cellType isKindOfClass:[NSNumber class]] == NO || cellType.integerValue != 26) continue;
            id actionObject = DYStorageValue(item, @"cellTappedBlock");
            if ([NSStringFromClass([actionObject class]) containsString:@"Block"] == NO) continue;
            NSString *title = DYStorageStringValue(item, @"title");
            if (title.length == 0) continue;
            if ([DYStorageNormalizedString(title) isEqualToString:normalizedFeature]) continue;
            if (title.length > 24) continue;
            if (DYStorageHeaderLooksLikeSystemGroup(title)) continue;
            if ([titles containsObject:title] == NO) [titles addObject:title];
        }
    }
    return titles;
}

/// Walks one level of plug-in category rows when the catalog route is empty.
/// It never runs on the organizer page, never repeats a row, and pops back once
/// when a group turns out not to contain the requested row.
static void DYStorageTryDescendTowardsFeature(UIViewController *controller, NSString *featureTitle) {
    if (controller == nil || featureTitle.length == 0) return;
    if (controller == gDYStoragePendingSourceController) return;
    if (gDYStorageDescentDepth >= 2) return;
    // A plug-in that ships its own search box is served by the native search
    // path, so do not open unrelated categories behind the user's back.
    if (DYStorageFindSettingsSearchField(controller.viewIfLoaded, 16) != nil) return;

    if (controller != gDYStorageDescentPage) {
        gDYStorageDescentPage = controller;
        gDYStorageDescentQueue = [DYStorageNavigationCandidateTitles(controller, featureTitle) mutableCopy];
    }
    if (gDYStorageDescentVisited == nil) gDYStorageDescentVisited = [NSMutableSet set];
    NSString *pageKey = DYStorageNormalizedString(controller.title ?: controller.navigationItem.title);
    while (gDYStorageDescentQueue.count > 0) {
        NSString *candidate = gDYStorageDescentQueue.firstObject;
        [gDYStorageDescentQueue removeObjectAtIndex:0];
        NSString *key = [NSString stringWithFormat:@"%@|%@", pageKey ?: @"",
                         DYStorageNormalizedString(candidate)];
        if ([gDYStorageDescentVisited containsObject:key]) continue;
        [gDYStorageDescentVisited addObject:key];
        if (DYStorageInvokeSettingsNavigationItem(controller, candidate)) {
            gDYStorageDescentDepth += 1;
            gDYStorageDescentPage = nil;
            DYStorageLog(@"Descend into %@ for %@", candidate, featureTitle);
            return;
        }
    }
    if (gDYStorageDescentDepth > 0) {
        UINavigationController *navigationController = controller.navigationController;
        gDYStorageDescentDepth -= 1;
        gDYStorageDescentPage = nil;
        if (navigationController != nil) {
            [navigationController popViewControllerAnimated:NO];
        }
    }
}

static BOOL DYStorageTryLocateFeature(UIViewController *sourceController,
                                      NSString *section,
                                      NSString *title) {
    if (!sourceController || !title.length) return NO;
    gDYStorageFeatureScanHasMoreRows = NO;
    UIViewController *topController = DYStorageTopViewController(nil);
    if (DYStorageResolveFeatureInController(topController, sourceController, section, title)) {
        return YES;
    }
    BOOL floatingPlugin = gDYStoragePendingFloatingRouteCandidates.count > 0;
    if (floatingPlugin == NO) DYStorageTryDescendTowardsFeature(topController, title);
    if (DYStorageLocateFeatureInVisibleWindows(sourceController,
                                               gDYStoragePendingPlugin,
                                               title,
                                               floatingPlugin)) return YES;

    // Floating plug-ins do not push a UIViewController, so viewDidAppear cannot
    // advance their internal pages. Select one known-safe category/config row
    // per retry, then let the next retry locate the target in the updated table.
    if (gDYStoragePendingFloatingRouteCandidates.count == 0 ||
        !DYStorageFloatingPluginPanelIsVisible(sourceController, gDYStoragePendingPlugin)) return NO;
    if (gDYStorageFeatureScanHasMoreRows) return NO;
    NSUInteger startIndex = gDYStoragePendingFloatingRouteIndex;
    for (NSUInteger index = startIndex;
        index < gDYStoragePendingFloatingRouteCandidates.count;
         index++) {
        NSString *candidate = gDYStoragePendingFloatingRouteCandidates[index];
        if (!DYStorageActivateFloatingRouteInVisibleWindows(sourceController,
                                                             gDYStoragePendingPlugin,
                                                             candidate)) continue;
        gDYStoragePendingFloatingRouteIndex = index + 1;
        break;
    }
    return NO;
}

static void DYStorageResolvePendingFeatureForController(UIViewController *controller) {
    NSUInteger generation = gDYStorageFeatureNavigationGeneration;
    NSString *section = gDYStoragePendingFeatureSection;
    NSString *title = gDYStoragePendingFeatureTitle;
    UIViewController *sourceController = gDYStoragePendingSourceController;
    if (!controller || !title.length || controller == sourceController) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gDYStorageFeatureNavigationGeneration) return;
        if (!controller.viewIfLoaded.window) return;
        if (DYStorageResolveFeatureInController(controller, sourceController, section, title)) {
            DYStorageClearPendingFeatureNavigation(generation);
            return;
        }
        // Native plug-in search updates sectionDataArray synchronously in most
        // versions, but allow one table reload/layout turn before resolving.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != gDYStorageFeatureNavigationGeneration) return;
            if (!controller.viewIfLoaded.window) return;
            if (DYStorageResolveFeatureInController(controller, sourceController, section, title)) {
                DYStorageClearPendingFeatureNavigation(generation);
            }
        });
    });
}

/// Short, non-blocking hint shown when the plug-in page was reached but the row
/// could not be located. It keeps a partial result honest instead of leaving the
/// user staring at an unchanged page.
static void DYStorageShowLocateHint(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = DYStorageKeyWindow();
        if (window == nil) return;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.text = @"\u5df2\u6253\u5f00\u63d2\u4ef6\u8bbe\u7f6e\uff0c\u672a\u80fd\u81ea\u52a8\u5b9a\u4f4d\u5230\u8fd9\u4e00\u9879";
        label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        label.layer.cornerRadius = 10.0;
        label.layer.masksToBounds = YES;
        label.numberOfLines = 2;
        [label sizeToFit];
        CGRect frame = label.frame;
        frame.size.width += 28.0;
        frame.size.height += 16.0;
        frame.origin.x = (CGRectGetWidth(window.bounds) - frame.size.width) / 2.0;
        frame.origin.y = CGRectGetHeight(window.bounds) - frame.size.height - 96.0;
        label.frame = frame;
        label.alpha = 0.0;
        [window addSubview:label];
        [UIView animateWithDuration:0.18 animations:^{
            label.alpha = 1.0;
        } completion:^(__unused BOOL finished) {
            [UIView animateWithDuration:0.35 delay:1.6 options:0 animations:^{
                label.alpha = 0.0;
            } completion:^(__unused BOOL finished) {
                [label removeFromSuperview];
            }];
        }];
    });
}

static void DYStorageScheduleFeatureRetry(UIViewController *sourceController,
                                          NSString *section,
                                          NSString *title,
                                          NSArray<NSNumber *> *intervals,
                                          NSUInteger intervalIndex,
                                          NSUInteger generation) {
    if (generation != gDYStorageFeatureNavigationGeneration) return;
    if (intervalIndex >= intervals.count) {
        UIViewController *topController = DYStorageTopViewController(nil);
        BOOL leftTheOrganizer = topController != nil &&
            topController != gDYStoragePendingSourceController;
        DYStorageClearPendingFeatureNavigation(generation);
        if (leftTheOrganizer) DYStorageShowLocateHint();
        return;
    }

    __weak UIViewController *weakSourceController = sourceController;
    NSTimeInterval delay = intervals[intervalIndex].doubleValue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gDYStorageFeatureNavigationGeneration) return;
        UIViewController *strongSourceController = weakSourceController;
        if (!strongSourceController) {
            DYStorageClearPendingFeatureNavigation(generation);
            return;
        }
        if (DYStorageTryLocateFeature(strongSourceController, section, title)) {
            DYStorageClearPendingFeatureNavigation(generation);
            return;
        }
        DYStorageScheduleFeatureRetry(strongSourceController,
                                      section,
                                      title,
                                      intervals,
                                      intervalIndex + 1,
                                      generation);
    });
}

static void DYStorageOpenAndLocateFeature(UIViewController *sourceController,
                                          DYStorageAction openPlugin,
                                          NSString *plugin,
                                          NSArray<NSString *> *route,
                                          NSString *section,
                                          NSString *title) {
    if (!sourceController || !openPlugin || !plugin.length || !title.length) return;
    NSUInteger generation = ++gDYStorageFeatureNavigationGeneration;
    gDYStoragePendingSourceController = sourceController;
    gDYStoragePendingFeatureSection = [section copy];
    gDYStoragePendingFeatureTitle = [title copy];
    gDYStoragePendingFeatureRoute = [route copy] ?: @[];
    gDYStoragePendingFeatureRouteIndex = 0;
    gDYStorageLastRouteController = nil;
    gDYStoragePendingFloatingRouteCandidates =
        [DYStorageFloatingRouteCandidatesForFeature(plugin, title) copy];
    gDYStoragePendingFloatingRouteIndex = 0;
    gDYStoragePendingPlugin = [plugin copy];
    gDYStorageInvokedItemKeys = [NSMutableSet set];
    gDYStorageInvocationCount = 0;
    gDYStorageDescentQueue = nil;
    gDYStorageDescentVisited = [NSMutableSet set];
    gDYStorageDescentPage = nil;
    gDYStorageDescentDepth = 0;
    @try {
        openPlugin();
    } @catch (__unused NSException *exception) {
        DYStorageClearPendingFeatureNavigation(generation);
        return;
    }

    // Keep only one retry block queued at a time. Rapidly choosing another
    // result invalidates the generation, so old searches drain without leaving
    // a group of delayed scans on the main queue.
    NSArray<NSNumber *> *intervals = @[ @0.18, @0.24, @0.32, @0.42, @0.55,
                                        @0.70, @0.85, @0.90, @0.90, @0.90,
                                        @0.90, @0.90, @0.90, @0.90 ];
    DYStorageScheduleFeatureRetry(sourceController, section, title, intervals, 0, generation);
}

static NSArray *DYStorageAggregateSearchSections(NSString *searchText, UIViewController *sourceController) {
    NSString *query = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) return DYStorageHubSections();

    NSDictionary<NSString *, NSDictionary *> *targets = DYStorageInstalledSearchTargets();
    NSMutableDictionary<NSString *, NSMutableArray *> *groupedItems = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *orderedPaths = [NSMutableArray array];
    NSUInteger resultIndex = 0;

    for (NSDictionary *catalogEntry in DYStorageSearchCatalogMerged()) {
        NSString *plugin = catalogEntry[@"plugin"];
        NSDictionary *target = targets[plugin];
        DYStorageAction action = (DYStorageAction)target[@"action"];
        if (plugin.length == 0 || !action) continue;

        NSArray<NSString *> *aliases = catalogEntry[@"aliases"] ?: @[];
        for (NSDictionary *feature in catalogEntry[@"features"]) {
            NSString *title = feature[@"title"];
            NSString *section = feature[@"section"] ?: @"功能";
            NSArray<NSString *> *route = DYStorageNavigationRouteForFeature(plugin, feature);
            // DYYY's scanned model contained XUU's independently injected root
            // entry. It is not a DYYY feature and must not appear unless the
            // actual assistant plug-in is installed as its own catalog target.
            if ([plugin isEqualToString:@"DYYY"] &&
                ([section hasPrefix:@"XUU"] || [section hasPrefix:@"𝙓𝙐𝙐"] ||
                 DYStorageTitleMatchesCatalogAlias(title, @"抖音助手"))) {
                continue;
            }
            NSMutableArray<NSString *> *searchable = [NSMutableArray arrayWithObjects:plugin, section, title ?: @"", nil];
            [searchable addObjectsFromArray:aliases];
            if (!DYStorageSearchTextMatches(query, searchable)) continue;

            NSString *path = section.length ? [NSString stringWithFormat:@"%@ - %@", plugin, section] : plugin;
            NSMutableArray *items = groupedItems[path];
            if (!items) {
                items = [NSMutableArray array];
                groupedItems[path] = items;
                [orderedPaths addObject:path];
            }
            NSString *identifier = [NSString stringWithFormat:@"com.xlzs001.dystorage.search.%lu", (unsigned long)resultIndex++];
            __weak UIViewController *weakSourceController = sourceController;
            DYStorageAction resultAction = ^{
                DYStorageOpenAndLocateFeature(weakSourceController, action, plugin, route, section, title);
            };
            id resultItem = DYStorageMakeItem(identifier,
                                              title ?: @"未命名功能",
                                              [NSString stringWithFormat:@"点击定位 %@ 中的此功能", target[@"installedTitle"] ?: plugin],
                                              target[@"icon"],
                                              resultAction);
            if (resultItem) [items addObject:resultItem];
        }
    }

    NSMutableArray *sections = [NSMutableArray array];
    for (NSString *path in orderedPaths) {
        NSArray *items = groupedItems[path];
        if (items.count == 0) continue;
        NSString *identifier = [NSString stringWithFormat:@"com.xlzs001.dystorage.search.section.%lu",
                                  (unsigned long)sections.count];
        id section = DYStorageMakeSection(identifier, path, items);
        if (section) [sections addObject:section];
    }

    if (sections.count == 0) {
        NSString *detail = targets.count
            ? @"请尝试其他关键词"
            : @"当前没有已安装且已建立搜索目录的插件";
        id emptyItem = DYStorageMakeItem(@"com.xlzs001.dystorage.search.empty",
                                         @"未找到相关设置",
                                         detail,
                                         @"ic_search_outlined_20",
                                         nil);
        id emptySection = DYStorageMakeSection(@"com.xlzs001.dystorage.search.empty-section",
                                                @"聚合搜索",
                                                emptyItem ? @[ emptyItem ] : @[]);
        if (emptySection) [sections addObject:emptySection];
    }
    return sections;
}

static void DYStorageInstallAggregateSearch(UIViewController *controller) {
    if (!controller || objc_getAssociatedObject(controller, kDYStorageSearchCoordinatorAssociationKey)) return;
    id viewModel = objc_getAssociatedObject(controller, kDYStorageViewModelAssociationKey);
    if (!viewModel) return;
    __weak UIViewController *weakController = controller;
    DYStorageSearchCoordinator *coordinator =
        [DYStorageSearchCoordinator installOnController:controller
                                               viewModel:viewModel
                                        sectionsProvider:^NSArray *(NSString *query) {
                                            return DYStorageAggregateSearchSections(query, weakController);
                                        }];
    if (coordinator) {
        objc_setAssociatedObject(controller,
                                 kDYStorageSearchCoordinatorAssociationKey,
                                 coordinator,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIView *DYStorageMakeAboutFooter(void) {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 112)];
    footer.backgroundColor = UIColor.clearColor;
    footer.accessibilityIdentifier = @"DYStorageAboutFooter";

    UILabel *(^label)(NSString *, CGFloat) = ^UILabel *(NSString *text, CGFloat size) {
        UILabel *view = [[UILabel alloc] init];
        view.text = text;
        view.textAlignment = NSTextAlignmentCenter;
        view.textColor = [UIColor secondaryLabelColor];
        view.font = [UIFont systemFontOfSize:size];
        view.translatesAutoresizingMaskIntoConstraints = NO;
        return view;
    };
    UILabel *version = label([NSString stringWithFormat:@"Version: %@", kDYStorageVersion], 14.0);
    UILabel *author = label(@"Developed by xlzs001", 13.0);
    UIButton *repository = [UIButton buttonWithType:UIButtonTypeSystem];
    [repository setTitle:@"GitHub: xlzs001/DYstorage" forState:UIControlStateNormal];
    repository.titleLabel.font = [UIFont systemFontOfSize:13.0];
    repository.translatesAutoresizingMaskIntoConstraints = NO;
    [repository addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        NSURL *url = [NSURL URLWithString:kDYStorageRepositoryURL];
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:version];
    [footer addSubview:author];
    [footer addSubview:repository];
    [NSLayoutConstraint activateConstraints:@[
        [version.topAnchor constraintEqualToAnchor:footer.topAnchor constant:14],
        [version.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [author.topAnchor constraintEqualToAnchor:version.bottomAnchor constant:7],
        [author.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [repository.topAnchor constraintEqualToAnchor:author.bottomAnchor constant:10],
        [repository.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [repository.bottomAnchor constraintLessThanOrEqualToAnchor:footer.bottomAnchor constant:-8]
    ]];
    return footer;
}

static void DYStorageInstallAboutFooter(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) return;
    UIView *footer = DYStorageMakeAboutFooter();
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:footer];
    UITableView *tableView = DYStorageFindTableView(controller.view, 6);
    if (tableView) {
        UIEdgeInsets inset = tableView.contentInset;
        inset.bottom = MAX(inset.bottom, 112.0);
        tableView.contentInset = inset;
        tableView.scrollIndicatorInsets = inset;
    }
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:112.0]
    ]];
}

static NSArray *DYStorageHubSections(void) {
    DYStorageManager *manager = [DYStorageManager sharedManager];
    DYStorageDeveloperScanner *scanner = [DYStorageDeveloperScanner sharedScanner];
    BOOL developerUIEnabled = DYStorageDeveloperUIEnabled();
    // A scan uses a repeating main-run-loop timer. If developer mode was
    // disabled while a scan was active, stop it here so a hidden scanner can
    // never keep traversing the complete window hierarchy indefinitely.
    if (!developerUIEnabled && scanner.isScanning) [scanner stopScanning];
    NSArray *capturedItems = [manager capturedSettingsItems];
    NSArray<DYStorageRegistration *> *registeredPlugins = [manager registeredPlugins];
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];

    if (capturedItems.count) {
        NSMutableArray *displayItems = [NSMutableArray arrayWithCapacity:capturedItems.count];
        for (id item in capturedItems) {
            NSString *key = DYStorageItemKey(item);
            if (key.length) [seenKeys addObject:key];

            id displayItem = item;
            NSString *captureTitle = DYStorageStringValue(item, @"title");
            id captureActionObject = DYStorageValue(item, @"cellTappedBlock");
            if (captureTitle.length &&
                [NSStringFromClass([captureActionObject class]) containsString:@"Block"]) {
                DYStorageAction originalCaptureAction = (DYStorageAction)[captureActionObject copy];
                id captureItem = DYStorageMakeItem(DYStorageStringValue(item, @"identifier") ?: [@"capture:" stringByAppendingString:captureTitle],
                                                   DYStorageStringValue(item, @"title") ?: captureTitle,
                                                   DYStorageStringValue(item, @"detail") ?: @"",
                                                   DYStorageStringValue(item, @"svgIconImageName") ?: DYStorageStringValue(item, @"iconImageName"),
                                                   ^{
                                                       DYStorageBeginPluginPageCapture(captureTitle);
                                                       originalCaptureAction();
                                                   });
                if (captureItem) displayItem = captureItem;
            }
            if (scanner.isScanning) {
                NSString *title = DYStorageStringValue(item, @"title") ?: @"未命名插件";
                NSString *identifier = DYStorageStringValue(item, @"identifier") ?: [@"scan:" stringByAppendingString:title];
                NSString *detail = DYStorageStringValue(item, @"detail") ?: @"";
                NSString *iconName = DYStorageStringValue(item, @"svgIconImageName") ?: DYStorageStringValue(item, @"iconImageName");
                id actionObject = DYStorageValue(item, @"cellTappedBlock");
                if ([NSStringFromClass([actionObject class]) containsString:@"Block"]) {
                    DYStorageAction originalAction = (DYStorageAction)[actionObject copy];
                    id wrappedItem = DYStorageMakeItem(identifier, title, detail, iconName, ^{
                        [[DYStorageDeveloperScanner sharedScanner] selectPluginWithTitle:title];
                        DYStorageBeginPluginPageCapture(title);
                        originalAction();
                    });
                    if (wrappedItem) displayItem = wrappedItem;
                }
            }
            [displayItems addObject:displayItem];
        }
        id capturedSection = DYStorageMakeSection(kDYStorageHubContentIdentifier, @"已收纳的插件", displayItems);
        if (capturedSection) [sections addObject:capturedSection];
    }

    NSMutableArray *registeredItems = [NSMutableArray array];
    for (DYStorageRegistration *registration in registeredPlugins) {
        NSString *titleKey = DYStorageNormalizedString(registration.title);
        if (titleKey.length && ([seenKeys containsObject:[@"title:" stringByAppendingString:titleKey]] ||
                                [seenKeys containsObject:[@"identifier:" stringByAppendingString:titleKey]])) {
            continue;
        }

        __weak DYStorageRegistration *weakRegistration = registration;
        id item = DYStorageMakeItem([@"com.xlzs001.dystorage.registration." stringByAppendingString:registration.identifier ?: @"item"],
                                    registration.title,
                                    registration.version,
                                    @"ic_gearsimplify_outlined_20",
                                    ^{
                                        if ([DYStorageDeveloperScanner sharedScanner].isScanning) {
                                            [[DYStorageDeveloperScanner sharedScanner] selectPluginWithTitle:weakRegistration.title];
                                        }
                                        DYStorageOpenRegistration(weakRegistration);
                                    });
        if (item) [registeredItems addObject:item];
    }
    if (registeredItems.count) {
        id registeredSection = DYStorageMakeSection(@"com.xlzs001.dystorage.registered", @"主动接入", registeredItems);
        if (registeredSection) [sections addObject:registeredSection];
    }

    NSArray *candidateSections = DYStorageCandidateSections();
    if (candidateSections.count) {
        NSMutableArray *candidateItems = [NSMutableArray array];
        NSMutableSet<NSString *> *seenCandidates = [NSMutableSet set];
        for (id section in candidateSections) {
            for (id item in DYStorageArrayValue(section, @"itemArray")) {
                NSString *title = DYStorageStringValue(item, @"title");
                NSString *normalized = DYStorageNormalizedString(title);
                if (normalized.length == 0 || [seenCandidates containsObject:normalized]) continue;
                [seenCandidates addObject:normalized];
                id candidateItem = DYStorageMakeItem([@"com.xlzs001.dystorage.candidate." stringByAppendingString:normalized],
                                                     title,
                                                     @"点击收纳这个入口 (返回设置页后生效)",
                                                     @"ic_gearsimplify_outlined_20",
                                                     ^{
                    if (DYStorageConfirmPluginTitle(title)) {
                        DYStorageLog(@"Confirmed plug-in entry: %@", title);
                    }
                    DYStorageRefreshHubController(DYStorageTopViewController(nil));
                });
                if (candidateItem) [candidateItems addObject:candidateItem];
            }
        }
        if (candidateItems.count > 24) {
            [candidateItems removeObjectsInRange:NSMakeRange(24, candidateItems.count - 24)];
        }
        if (candidateItems.count) {
            id candidateSection = DYStorageMakeSection(@"com.xlzs001.dystorage.candidates",
                                                       @"发现的插件入口",
                                                       candidateItems);
            if (candidateSection) [sections addObject:candidateSection];
        }
    }

    if (developerUIEnabled) {
        NSString *scannerTitle = scanner.isScanning ? @"结束扫描并导出" : @"开发者扫描";
        NSString *scannerDetail = scanner.isScanning
            ? [NSString stringWithFormat:@"已记录 %lu 个功能，点击生成 JSON", (unsigned long)scanner.recordCount]
            : @"记录插件设置页中的功能名称和位置";
        id scannerItem = DYStorageMakeItem(@"com.xlzs001.dystorage.developer-scan",
                                           scannerTitle,
                                           scannerDetail,
                                           @"ic_search_outlined_20",
                                           ^{
                                               DYStorageDeveloperScanner *activeScanner = [DYStorageDeveloperScanner sharedScanner];
                                               UIViewController *presenter = DYStorageTopViewController(nil);
                                               if (!activeScanner.isScanning) {
                                                   [activeScanner startNewScan];
                                                   UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开发者扫描已开始"
                                                                                                                  message:@"请一次只打开一个插件，展开所有分类并缓慢滚动到底部；每个页面停留约 1 秒。悬浮窗会优先扫描最上层窗口。完成后返回 DYStorage，点击“结束扫描并导出”。"
                                                                                                           preferredStyle:UIAlertControllerStyleAlert];
                                                   [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                                                   [presenter presentViewController:alert animated:YES completion:nil];
                                                   DYStorageRefreshHubController(presenter);
                                                   return;
                                               }

                                               [activeScanner stopScanning];
                                               NSError *error = nil;
                                               if (![activeScanner exportReportFromController:presenter error:&error]) {
                                                   UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导出失败"
                                                                                                                  message:error.localizedDescription ?: @"无法生成扫描数据"
                                                                                                           preferredStyle:UIAlertControllerStyleAlert];
                                                   [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                                                   [presenter presentViewController:alert animated:YES completion:nil];
                                               }
                                               DYStorageRefreshHubController(presenter);
                                           });
        id scannerSection = DYStorageMakeSection(@"com.xlzs001.dystorage.developer-tools",
                                                 @"开发者工具",
                                                 scannerItem ? @[ scannerItem ] : @[]);
        if (scannerSection) [sections addObject:scannerSection];
    }

    if (capturedItems.count == 0 && registeredItems.count == 0) {
        id emptyItem = DYStorageMakeItem(@"com.xlzs001.dystorage.empty",
                                         @"暂无可收纳的插件",
                                         @"打开抖音设置后会自动识别已安装的兼容插件",
                                         @"ic_gearsimplify_outlined_20",
                                         nil);
        id emptySection = DYStorageMakeSection(kDYStorageHubContentIdentifier, @"已收纳的插件", emptyItem ? @[ emptyItem ] : @[]);
        if (emptySection) [sections addObject:emptySection];
    }
    return sections;
}

static void DYStorageRefreshHubController(UIViewController *controller) {
    id viewModel = objc_getAssociatedObject(controller, kDYStorageViewModelAssociationKey);
    if (!viewModel) return;
    DYStorageSearchCoordinator *coordinator =
        objc_getAssociatedObject(controller, kDYStorageSearchCoordinatorAssociationKey);
    if (coordinator) {
        // The coordinator owns the current normal/search query. Let it build
        // and install the model once instead of replacing it twice on every
        // appearance of the organizer page.
        [coordinator refreshWithCurrentQuery];
        return;
    }

    DYStorageSetValue(viewModel, DYStorageHubSections(), @"sectionDataArray");
    if (controller.isViewLoaded) {
        DYStorageReloadListsInView(controller.view, 5);
    }
}

static void DYStorageShowHub(UIViewController *rootController) {
    void (^show)(void) = ^{
        Class controllerClass = objc_lookUpClass("AWESettingBaseViewController");
        Class viewModelClass = objc_lookUpClass("AWESettingsViewModel");
        if (!controllerClass || !viewModelClass) return;

        UIViewController *controller = [[controllerClass alloc] init];
        id viewModel = [[viewModelClass alloc] init];
        if (!controller || !viewModel) return;

        DYStorageSetValue(viewModel, @2, @"colorStyle");
        DYStorageSetValue(viewModel, controller, @"controllerDelegate");
        DYStorageSetValue(viewModel, DYStorageHubSections(), @"sectionDataArray");
        objc_setAssociatedObject(controller,
                                 kDYStorageViewModelAssociationKey,
                                 viewModel,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        controller.title = @"DYStorage";
        DYStoragePresentController(controller, rootController);
    };
    if ([NSThread isMainThread]) show();
    else dispatch_async(dispatch_get_main_queue(), show);
}

#pragma mark - Settings data-source transformation

static BOOL DYStorageSectionIsTargetPlugin(id section) {
    return DYStorageTitleIsTargetPlugin(DYStorageStringValue(section, @"sectionHeaderTitle"));
}

static BOOL DYStorageItemIsTargetPlugin(id item) {
    return DYStorageTitleIsTargetPlugin(DYStorageStringValue(item, @"title"));
}

/// Both referenced DYYY branches inject exactly one root item into a section
/// titled "DYYY". Restrict the fallback path to that shape so a plugin's own
/// multi-row settings page can never be mistaken for its root entry.
static BOOL DYStorageIsStandalonePluginEntrySection(id section, NSArray *items) {
    if (!DYStorageSectionIsTargetPlugin(section) || items.count != 1) return NO;
    return DYStorageItemIsTargetPlugin(items.firstObject);
}

/// Late-hook fallback is intentionally stricter than normal collection. Both
/// DYYY variants use `sectionHeaderTitle == item.identifier == item.title` and
/// cellType 26 for their one-row root entry. Requiring that shape avoids hiding
/// an unrelated one-row section merely because its visible title overlaps.
static BOOL DYStorageIsFallbackPluginEntrySection(id section, NSArray *items) {
    if (!DYStorageIsStandalonePluginEntrySection(section, items)) {
        // XUU's current build puts “抖音助手” in a one-row section headed
        // “XUUᶻ”, so it cannot satisfy the usual title==identifier shape.
        // Keep this exception exact to avoid hiding ordinary settings groups.
        if (items.count != 1) return NO;
        NSString *header = DYStorageNormalizedString(DYStorageStringValue(section, @"sectionHeaderTitle"));
        id item = items.firstObject;
        if (![header isEqualToString:@"xuuᶻ"] && ![header isEqualToString:@"xuu"]) return NO;
        if (!DYStorageItemIsTargetPlugin(item) ||
            ![DYStorageNormalizedString(DYStorageStringValue(item, @"title")) isEqualToString:@"抖音助手"]) return NO;
        return YES;
    }

    id item = items.firstObject;
    NSString *sectionTitle = DYStorageNormalizedString(DYStorageStringValue(section, @"sectionHeaderTitle"));
    NSString *itemIdentifier = DYStorageNormalizedString(DYStorageStringValue(item, @"identifier"));
    NSString *itemTitle = DYStorageNormalizedString(DYStorageStringValue(item, @"title"));
    NSNumber *cellType = DYStorageValue(item, @"cellType");
    return sectionTitle.length && [itemIdentifier isEqualToString:sectionTitle] &&
           [itemTitle isEqualToString:sectionTitle] &&
           [cellType isKindOfClass:[NSNumber class]] && cellType.integerValue == 26;
}

static id DYStorageMakeHubEntrySection(id viewModel) {
    __weak id weakViewModel = viewModel;
    DYStorageManager *manager = [DYStorageManager sharedManager];
    NSUInteger count = [manager capturedSettingsItems].count + [manager registeredPlugins].count;
    NSString *detail = count ? [NSString stringWithFormat:@"已收纳 %lu 个", (unsigned long)count] : @"集中管理第三方插件设置";

    id entry = DYStorageMakeItem(kDYStorageHubEntryIdentifier,
                                 @"插件收纳",
                                 detail,
                                 @"ic_gearsimplify_outlined_20",
                                 ^{
                                     UIViewController *root = DYStorageValue(weakViewModel, @"controllerDelegate");
                                     DYStorageShowHub(root);
                                 });
    return entry ? DYStorageMakeSection(kDYStorageHubSectionIdentifier, @"DYStorage", @[ entry ]) : nil;
}

static NSArray *DYStorageOrganizedMainSections(id viewModel, NSArray *originalSections) {
    if (![originalSections isKindOfClass:[NSArray class]] || originalSections.count == 0) return originalSections;
    if (!DYStorageLooksLikeMainSettingsPage(originalSections)) return originalSections;
    if (gDYStorageOrganizingMainSections) return originalSections;

    gDYStorageOrganizingMainSections = YES;
    NSArray *result = originalSections;
    @try {
        NSMutableArray *finalSections = [NSMutableArray array];
        NSMutableArray *capturedItems = [NSMutableArray array];
        NSMutableArray *candidateSections = [NSMutableArray array];

        for (id section in originalSections) {
            if (DYStorageSectionIsHub(section)) continue; // refresh our own count and action block

            NSArray *items = DYStorageArrayValue(section, @"itemArray");
            // The fallback hook may already have captured a section that was
            // appended by an outer Hook. Do not leave its now-empty shell in a
            // subsequent pass through this data source.
            if (objc_getAssociatedObject(section, kDYStorageFallbackHiddenSectionKey)) continue;
            if (DYStorageIsStandalonePluginEntrySection(section, items)) {
                if (items.count) [capturedItems addObjectsFromArray:items];
                continue;
            }

            // Unconfirmed look-alikes stay where Douyin put them and are only
            // offered as a suggestion on the organizer page.
            if (DYStorageSectionLooksLikePluginEntryCandidate(section, items)) {
                [candidateSections addObject:section];
            }

            if (items.count == 0) {
                [finalSections addObject:section];
                continue;
            }

            NSMutableArray *remainingItems = [NSMutableArray arrayWithCapacity:items.count];
            NSMutableArray *targetItems = [NSMutableArray array];
            BOOL removedItem = NO;
            for (id item in items) {
                if (DYStorageItemIsHubEntry(item)) {
                    removedItem = YES;
                    continue;
                }
                if (DYStorageItemIsTargetPlugin(item)) {
                    [targetItems addObject:item];
                    removedItem = YES;
                } else {
                    [remainingItems addObject:item];
                }
            }

            if (!removedItem || targetItems.count == 0) {
                [finalSections addObject:section];
                continue;
            }

            if (remainingItems.count == 0) {
                [capturedItems addObjectsFromArray:targetItems];
            } else {
                id copiedSection = DYStorageCopySectionWithItems(section, remainingItems);
                // Only capture an item after its source section was copied
                // successfully. Otherwise the same private model could be owned by
                // two view models at once, so leave the original section untouched.
                if (copiedSection) {
                    [capturedItems addObjectsFromArray:targetItems];
                    [finalSections addObject:copiedSection];
                } else {
                    [finalSections addObject:section];
                }
            }
        }

        DYStorageSetCandidateSections(candidateSections);

        if (capturedItems.count) {
            [[DYStorageManager sharedManager] captureSettingsItems:capturedItems];
            DYStorageLog(@"Captured %lu settings items", (unsigned long)capturedItems.count);
        }

        id hubSection = DYStorageMakeHubEntrySection(viewModel);
        if (hubSection) {
            [finalSections insertObject:hubSection atIndex:0];
            gDYStorageHubInsertedOnMainSettings = YES;
        }
        result = finalSections;
    } @catch (NSException *exception) {
        // A malformed model from a third-party tweak must never take down
        // Douyin's settings page: hand back the untouched data source instead.
        DYStorageLog(@"Organizer aborted: %@", exception);
        result = originalSections;
    } @finally {
        gDYStorageOrganizingMainSections = NO;
    }
    return result;
}

#pragma mark - Delayed, selector-checked Logos installation

static void DYStorageInstallAvailableHooks(void);

%group DYStorageSettingsHooks
%hook DYStorageSettingsViewModelTarget

- (NSArray *)sectionDataArray {
    NSArray *sections = %orig;
    DYStorageCaptureFeaturesFromSections(sections);
    @try {
        // XUU hooks AWESettingsViewModel globally and can prepend its own section
        // after DYStorage has built the hub model. Never show that duplicate on
        // the organizer page; the preserved item already lives in our collection.
        for (id section in sections) {
            if (DYStorageSectionIsHubContent(section)) {
                return DYStorageRemoveXUUFromHubSections(sections);
            }
        }
        return DYStorageOrganizedMainSections(self, sections);
    } @catch (NSException *exception) {
        // The settings table view must always get a usable array back.
        DYStorageLog(@"sectionDataArray passthrough: %@", exception);
        return sections;
    }
}

%end
%end

%group DYStorageSectionFallbackHooks
%hook DYStorageSectionModelTarget

- (NSArray *)itemArray {
    NSArray *items = %orig;
    BOOL hideHubDuplicate = gDYStorageHubPageVisible && DYStorageIsXUUAssistantSectionWithItems(self, items);
    BOOL hideLateRoot = gDYStorageHubInsertedOnMainSettings && DYStorageIsFallbackPluginEntrySection(self, items);
    if (gDYStorageOrganizingMainSections || (!hideHubDuplicate && !hideLateRoot)) {
        return items;
    }

    if (hideLateRoot) [[DYStorageManager sharedManager] captureSettingsItems:items];
    objc_setAssociatedObject(self,
                             kDYStorageFallbackHiddenSectionKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // This path is only needed if a later-installed tweak appends its section
    // outside our sectionDataArray hook. The original click block is retained
    // in the hub, while the source table receives no duplicate row.
    return @[];
}

%end
%end

%group DYStorageSectionHeaderHooks
%hook DYStorageSectionHeaderTarget

- (CGFloat)sectionHeaderHeight {
    CGFloat height = %orig;
    // UIKit can ask for a section header before asking for its row count. Probe
    // the item model once in that order so the fallback can mark a qualifying
    // late-added root section before this height is returned.
    if (!objc_getAssociatedObject(self, kDYStorageFallbackHiddenSectionKey) &&
        !gDYStorageOrganizingMainSections && !gDYStorageCheckingFallbackHeader &&
        (gDYStorageHubInsertedOnMainSettings || gDYStorageHubPageVisible) &&
        DYStorageSectionIsTargetPlugin(self)) {
        gDYStorageCheckingFallbackHeader = YES;
        @try {
            (void)DYStorageArrayValue(self, @"itemArray");
        } @catch (__unused NSException *exception) {
            // Keep the original header if an unfamiliar private model rejects
            // the probe; DYStorage must never make that a page-level failure.
        } @finally {
            gDYStorageCheckingFallbackHeader = NO;
        }
    }
    return objc_getAssociatedObject(self, kDYStorageFallbackHiddenSectionKey) ? 0 : height;
}

%end
%end

%group DYStorageHubHooks
%hook DYStorageHubViewControllerTarget

- (id)viewModel {
    id customViewModel = objc_getAssociatedObject(self, kDYStorageViewModelAssociationKey);
    return customViewModel ?: %orig;
}

- (void)viewDidLoad {
    %orig;
    if (!objc_getAssociatedObject(self, kDYStorageViewModelAssociationKey)) return;
    [(UIViewController *)self setTitle:@"DYStorage"];
    gDYStorageHubPageVisible = YES;
    DYStorageRefreshHubController((UIViewController *)self);
    DYStorageInstallAboutFooter((UIViewController *)self);
    DYStorageInstallAggregateSearch((UIViewController *)self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    DYStorageSearchCoordinator *appearanceCoordinator =
        objc_getAssociatedObject(self, kDYStorageSearchCoordinatorAssociationKey);
    [appearanceCoordinator hostAppearanceDidChange];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    id customViewModel = objc_getAssociatedObject(self, kDYStorageViewModelAssociationKey);
    if (customViewModel) {
        gDYStorageHubPageVisible = YES;
        DYStorageRefreshHubController((UIViewController *)self);
        DYStorageInstallAggregateSearch((UIViewController *)self);
        DYStorageSearchCoordinator *coordinator =
            objc_getAssociatedObject(self, kDYStorageSearchCoordinatorAssociationKey);
        [coordinator pageDidAppear];
        return;
    }

    // A cross-plug-in search result may open this controller asynchronously.
    // Resolve the pending feature against this exact controller instead of
    // guessing which application window is currently key.
    DYStorageResolvePendingFeatureForController((UIViewController *)self);

    if ([DYStorageDeveloperScanner sharedScanner].isScanning) {
        __weak UIViewController *weakController = (UIViewController *)self;
        for (NSNumber *delay in @[ @0.25, @1.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIViewController *controller = weakController;
                if (!controller || ![DYStorageDeveloperScanner sharedScanner].isScanning) return;
                id viewModel = DYStorageValue(controller, @"viewModel");
                [[DYStorageDeveloperScanner sharedScanner] captureSettingsController:controller viewModel:viewModel];
            });
        }
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!objc_getAssociatedObject(self, kDYStorageViewModelAssociationKey)) return;
    DYStorageSearchCoordinator *coordinator =
        objc_getAssociatedObject(self, kDYStorageSearchCoordinatorAssociationKey);
    [coordinator updateLayout];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (objc_getAssociatedObject(self, kDYStorageViewModelAssociationKey)) {
        DYStorageSearchCoordinator *coordinator =
            objc_getAssociatedObject(self, kDYStorageSearchCoordinatorAssociationKey);
        [coordinator pageDidDisappear];
        [[(UIViewController *)self viewIfLoaded] endEditing:YES];
        gDYStorageHubPageVisible = NO;
    }
}

%end
%end

static void DYStorageInstallAvailableHooks(void) {
    Class settingsViewModelClass = objc_lookUpClass("AWESettingsViewModel");
    if (!gDYStorageSettingsHookInstalled && settingsViewModelClass &&
        class_getInstanceMethod(settingsViewModelClass, @selector(sectionDataArray))) {
        %init(DYStorageSettingsHooks, DYStorageSettingsViewModelTarget = settingsViewModelClass);
        gDYStorageSettingsHookInstalled = YES;
        DYStorageLog(@"Installed settings hook");
    }

    Class settingsControllerClass = objc_lookUpClass("AWESettingBaseViewController");
    if (!gDYStorageHubHookInstalled && settingsControllerClass &&
        class_getInstanceMethod(settingsControllerClass, @selector(viewModel))) {
        %init(DYStorageHubHooks, DYStorageHubViewControllerTarget = settingsControllerClass);
        gDYStorageHubHookInstalled = YES;
        DYStorageLog(@"Installed hub hook");
    }

    Class sectionModelClass = objc_lookUpClass("AWESettingSectionModel");
    if (!gDYStorageSectionFallbackHookInstalled && sectionModelClass &&
        class_getInstanceMethod(sectionModelClass, @selector(itemArray))) {
        %init(DYStorageSectionFallbackHooks, DYStorageSectionModelTarget = sectionModelClass);
        gDYStorageSectionFallbackHookInstalled = YES;
        DYStorageLog(@"Installed section fallback hook");
    }
    if (!gDYStorageSectionHeaderHookInstalled && sectionModelClass &&
        class_getInstanceMethod(sectionModelClass, @selector(sectionHeaderHeight))) {
        %init(DYStorageSectionHeaderHooks, DYStorageSectionHeaderTarget = sectionModelClass);
        gDYStorageSectionHeaderHookInstalled = YES;
        DYStorageLog(@"Installed section header hook");
    }
}

%ctor {
    @autoreleasepool {
        // DYYY installs its settings hook in its constructor. Installing ours on
        // later main-loop turns usually makes %orig observe that injected
        // section. A narrowly-scoped AWESettingSectionModel fallback below also
        // handles a root section appended by a later-installed Hook.
        dispatch_async(dispatch_get_main_queue(), ^{
            DYStorageInstallAvailableHooks();
            for (NSNumber *delay in @[ @0.5, @2.0 ]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                   DYStorageInstallAvailableHooks();
                               });
            }
        });

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        DYStorageInstallAvailableHooks();
                    }];
    }
}
