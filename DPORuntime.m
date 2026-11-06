

#import "DPORuntime.h"
#import <execinfo.h>
#import <string.h>
#import "DPOLogCenter.h"

NSString *const DPOEntryIdentifier = @"com.dpo.pluginnest.entry";
NSString *const DPOEntryTitle = @"插件";
NSString *const DPOBuildVersion = @"1.1.72";

#pragma mark - 类查找

Class DPOLookupClass(const char *name) {
    if (name == NULL) return Nil;
    Class cls = objc_getClass(name);
    if (cls == Nil) {
        NSString *string = [NSString stringWithUTF8String:name];
        if (string.length > 0) cls = NSClassFromString(string);
    }
    return cls;
}

BOOL DPOClassIs(id obj, const char *name) {
    Class cls = DPOLookupClass(name);
    if (cls == Nil || obj == nil) return NO;
    return [obj isKindOfClass:cls];
}

static __weak id DPOMainSettingsViewModelRef = nil;

void DPOSetMainSettingsViewModel(id vm) {
    if (vm == nil) return;
    if (DPOMainSettingsViewModelRef == vm) return;
    DPOMainSettingsViewModelRef = vm;
    DPOLogEvent(@"MAINVM", @"登记主设置页 VM：%@ <%p>", NSStringFromClass([vm class]), vm);
}

DPOSettingsViewModelKind DPOClassifySettingsViewModel(id vm) {
    if (vm == nil) return DPOSettingsViewModelKindUnknown;

    
    
    NSString *delegateName = @"";
    @try {
        id delegate = [vm controllerDelegate];
        if (delegate != nil) delegateName = NSStringFromClass([delegate class]) ?: @"";
    } @catch (__unused NSException *exception) {
        delegateName = @"";
    }

    
    
    id recorded = DPOMainSettingsViewModelRef;
    if (recorded != nil) {
        if (vm == recorded) return DPOSettingsViewModelKindMain;
        
        
        return delegateName.length > 0 ? DPOSettingsViewModelKindSubPage
                                       : DPOSettingsViewModelKindUnknown;
    }

    if (delegateName.length > 0) {
        return [delegateName containsString:@"SettingsTableViewController"]
                   ? DPOSettingsViewModelKindMain
                   : DPOSettingsViewModelKindSubPage;
    }

    
    
    
    
    
    return DPOSettingsViewModelKindUnknown;
}

BOOL DPOIsMainSettingsViewModel(id vm) {
    return DPOClassifySettingsViewModel(vm) == DPOSettingsViewModelKindMain;
}

#pragma mark - 日志

BOOL DPOLogEnabled(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *env = getenv("DPO_DEBUG");
        enabled = (env != NULL && env[0] != '\0' && env[0] != '0');
    });
    return enabled;
}

void DPOLogOnceMessage(NSString *message) {
    if (message.length == 0) return;
    static NSMutableSet<NSString *> *seen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableSet set];
    });
    @synchronized (seen) {
        if ([seen containsObject:message]) return;
        [seen addObject:message];
    }
    NSLog(@"[PluginNest] %@", message);
}

#pragma mark - 镜像判定

BOOL DPOIsThirdPartyImage(NSString *path) {
    if (path.length == 0) return NO;

    
    
    static NSArray<NSString *> *infraNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        infraNames = @[
            @"libsubstrate", @"CydiaSubstrate", @"SubstrateLoader",
            @"SubstrateBootstrap", @"SubstrateInserter", @"SubstrateDiagnose",
            @"ellekit", @"ElleKit", @"libhooker", @"rocketbootstrap",
            @"PreferenceLoader", @"libblackjack", @"libkrw",
            @"PluginNest", @"PluginOrganizer",
            @"libswift", @"libobjc", @"libc++abi", @"libSystem",
        ];
    });
    for (NSString *needle in infraNames) {
        if ([path containsString:needle]) return NO;
    }

    
    
    
    
    if ([path containsString:@"/Aweme.app/"]) {
        BOOL loosePluginDylib = [path containsString:@"/Frameworks/"] &&
                                [path.pathExtension isEqualToString:@"dylib"] &&
                                ![path containsString:@".framework/"];
        return loosePluginDylib ? YES : NO;
    }
    if ([path hasPrefix:@"/System/"]) return NO;
    
    
    if ([path hasPrefix:@"/private/preboot/Cryptexes/"]) return NO;
    if ([path hasPrefix:@"/Developer/"]) return NO;
    if ([path hasPrefix:@"/Library/Apple/"]) return NO;

    
    
    if ([path containsString:@"/TweakInject/"]) return YES;
    if ([path containsString:@"/DynamicLibraries/"]) return YES;
    if ([path hasPrefix:@"/var/jb/"]) return YES;
    if ([path hasPrefix:@"/Library/MobileSubstrate/"]) return YES;

    
    if ([path hasPrefix:@"/usr/lib/"]) return NO;

    
    
    if ([path.pathExtension isEqualToString:@"dylib"]) return YES;
    if ([path containsString:@".framework/"]) return YES;

    return NO;
}

#pragma mark - block 归属

typedef struct {
    void *isa;
    volatile int32_t flags;
    int32_t reserved;
    void *invoke;
    void *descriptor;
} DPOBlockLayout;

static void *DPOBlockInvoke(id block) {
    if (block == nil) return NULL;
    const void *bytes = (__bridge const void *)block;
    if (bytes == NULL) return NULL;

    DPOBlockLayout layout;
    memcpy(&layout, bytes, sizeof(layout));
    return layout.invoke;
}

static BOOL DPOObjectIsBlock(id object) {
    if (object == nil) return NO;
    Class cls = object_getClass(object);
    if (cls == Nil) return NO;
    const char *name = class_getName(cls);
    return name != NULL && strstr(name, "Block") != NULL;
}

NSString *DPOPluginImageForBlock(id block) {
    if (block == nil) return nil;
    if (!DPOObjectIsBlock(block)) return nil;

    void *invoke = DPOBlockInvoke(block);
    if (invoke == NULL) return nil;

    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(invoke, &info) == 0 || info.dli_fname == NULL) return nil;

    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    if (path.length == 0) return nil;
    return path;
}

static NSString *DPOImageForClassName(NSString *className) {
    if (className.length == 0) return nil;
    Class cls = NSClassFromString(className);
    if (cls == Nil) return nil;

    const char *image = class_getImageName(cls);
    if (image == NULL) return nil;

    NSString *path = [NSString stringWithUTF8String:image];
    if (!DPOIsThirdPartyImage(path)) return nil;
    return path;
}

NSString *DPOPluginImageForClass(Class cls) {
    if (cls == Nil) return nil;

    // 每次 cell 显示都会问一次，缓存按类名做：宿主类命中 NSNull 直接短路。
    static NSMutableDictionary<NSString *, id> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    NSString *key = NSStringFromClass(cls);
    if (key.length == 0) return nil;

    @synchronized (cache) {
        id hit = cache[key];
        if (hit != nil) return (hit == [NSNull null]) ? nil : (NSString *)hit;
    }

    NSString *path = nil;
    const char *image = class_getImageName(cls);
    if (image != NULL) {
        NSString *candidate = [NSString stringWithUTF8String:image];
        if (candidate.length > 0 &&
            ![candidate containsString:@"PluginNest"] &&      // 自己的类不算
            DPOIsThirdPartyImage(candidate)) {
            path = candidate;
        }
    }

    @synchronized (cache) {
        cache[key] = path ?: [NSNull null];
    }
    return path;
}

NSString *DPOPluginImageForItem(AWESettingItemModel *item) {
    if (item == nil) return nil;

    
    
    
    NSString *blockImage = nil;
    @try {
        blockImage = DPOPluginImageForBlock(item.cellTappedBlock);
        if (blockImage.length == 0) blockImage = DPOPluginImageForBlock(item.switchChangedBlock);
    } @catch (__unused NSException *exception) {
        blockImage = nil;
    }
    if (blockImage.length > 0) {
        if (DPOIsThirdPartyImage(blockImage)) return blockImage;
        DPOLogOnce(@"block 归属为宿主：%@", blockImage.lastPathComponent);
        return nil;
    }

    
    NSString *classImage = DPOImageForClassName(item.cellControllerClass);
    if (classImage.length > 0) return classImage;
    classImage = DPOImageForClassName(item.bizViewModelClass);
    if (classImage.length > 0) return classImage;

    
    NSString *className = item.cellControllerClass.length > 0 ? item.cellControllerClass
                                                               : item.bizViewModelClass;
    if (className.length > 0 && NSClassFromString(className) != Nil) {
        return nil;
    }

    
    NSString *associated = DPOAssociatedOwner(item);
    if (associated.length > 0) return associated;

    return nil;
}

BOOL DPOItemIsHostOwned(AWESettingItemModel *item) {
    if (item == nil) return NO;

    NSString *blockImage = nil;
    @try {
        blockImage = DPOPluginImageForBlock(item.cellTappedBlock);
        if (blockImage.length == 0) blockImage = DPOPluginImageForBlock(item.switchChangedBlock);
    } @catch (__unused NSException *exception) {
        blockImage = nil;
    }
    if (blockImage.length > 0) return !DPOIsThirdPartyImage(blockImage);

    NSString *className = item.cellControllerClass.length > 0 ? item.cellControllerClass
                                                               : item.bizViewModelClass;
    if (className.length > 0) {
        Class cls = NSClassFromString(className);
        if (cls != Nil) {
            const char *image = class_getImageName(cls);
            if (image == NULL) return YES;
            NSString *path = [NSString stringWithUTF8String:image];
            return !DPOIsThirdPartyImage(path);
        }
    }
    return NO;
}

#pragma mark - 创建时的归属捕获

static char kDPOOwnerAssociationKey;

void DPOCaptureOwnerForObject(id object) {
    if (object == nil) return;
    if (DPOAssociatedOwner(object) != nil) return;

    void *frames[48];
    int count = backtrace(frames, 48);
    if (count <= 2) return;

    for (int index = 2; index < count; index++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr(frames[index], &info) == 0 || info.dli_fname == NULL) continue;

        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        if (path.length == 0) continue;
        if ([path containsString:@"PluginNest"]) continue;
        if (!DPOIsThirdPartyImage(path)) continue;

        objc_setAssociatedObject(object, &kDPOOwnerAssociationKey, path,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
}

NSString *DPOAssociatedOwner(id object) {
    if (object == nil) return nil;
    id value = objc_getAssociatedObject(object, &kDPOOwnerAssociationKey);
    if ([value isKindOfClass:[NSString class]]) {
        NSString *path = (NSString *)value;
        return DPOIsThirdPartyImage(path) ? path : nil;
    }
    return nil;
}

#pragma mark - 窗口 / 顶层控制器

UIWindow *DPOKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
            if (fallback == nil && !window.hidden) fallback = window;
        }
    }
    return fallback;
}

static UIViewController *DPODigTopViewControllerDepth(UIViewController *root, NSUInteger depth) {
    if (root == nil) return nil;
    
    
    if (depth > 12) return root;

    UIViewController *current = root;
    NSUInteger guard = 0;

    while (current.presentedViewController != nil && guard < 16) {
        UIViewController *next = current.presentedViewController;
        if (next == nil || next == current) break;
        current = next;
        guard += 1;
    }

    if ([current isKindOfClass:[UIAlertController class]]) {
        UIViewController *presenting = current.presentingViewController;
        if (presenting != nil) return DPODigTopViewControllerDepth(presenting, depth + 1);
        return current;
    }

    if ([current isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)current;
        UIViewController *top = nav.visibleViewController ?: nav.topViewController;
        if (top != nil && top != nav) return DPODigTopViewControllerDepth(top, depth + 1);
    } else if ([current isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)current;
        if (tab.selectedViewController != nil) {
            return DPODigTopViewControllerDepth(tab.selectedViewController, depth + 1);
        }
    }
    return current;
}

static UIViewController *DPODigTopViewController(UIViewController *root) {
    return DPODigTopViewControllerDepth(root, 0);
}

UIViewController *DPOTopViewController(void) {
    UIWindow *window = DPOKeyWindow();
    UIViewController *root = window.rootViewController;
    if (root == nil) return nil;
    return DPODigTopViewController(root);
}

static void DPOCollectLabels(UIView *view, NSMutableArray<UILabel *> *out, NSInteger depth) {
    if (view == nil || depth > 4) return;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            [out addObject:(UILabel *)subview];
        }
        DPOCollectLabels(subview, out, depth + 1);
    }
}

NSString *DPOCellTitle(UITableViewCell *cell) {
    if (cell == nil) return nil;

    NSString *text = cell.textLabel.text;
    if (text.length > 0) return text;

    // 插件自绘的 cell 把标题藏在多层容器里，只扫一层会漏。这里递归收集候选，
    // 用窗口坐标挑「最靠上、最靠左」的那个——那基本就是主标题。
    NSMutableArray<UILabel *> *candidates = [NSMutableArray array];
    DPOCollectLabels(cell.contentView, candidates, 0);

    UILabel *best = nil;
    CGRect bestRect = CGRectZero;
    for (UILabel *label in candidates) {
        NSString *value = label.text;
        if (value.length < 2 || value.length > 24) continue;
        if (label.hidden || label.alpha < 0.1) continue;

        CGRect rect = [label convertRect:label.bounds toView:nil];
        if (best == nil) {
            best = label;
            bestRect = rect;
            continue;
        }
        if (label.numberOfLines == 0 && best.numberOfLines != 0) continue;   // 多行是说明，优先单行
        if (rect.origin.y < bestRect.origin.y - 1.0 ||
            (fabs(rect.origin.y - bestRect.origin.y) <= 1.0 && rect.origin.x < bestRect.origin.x)) {
            best = label;
            bestRect = rect;
        }
    }
    if (best.text.length > 0) return best.text;

    NSString *accessibility = cell.accessibilityLabel;
    return accessibility.length > 0 ? accessibility : nil;
}

static UITableView *DPOFirstTableViewInView(UIView *view, NSInteger depth) {
    if (view == nil || depth > 4) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *found = DPOFirstTableViewInView(subview, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

UITableView *DPOTopmostTableView(void) {
    UIViewController *top = DPOTopViewController();
    if (top == nil) return nil;

    // 先看当前页及其子控制器，再退回它的 view 层级里找。
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:top];
    for (NSUInteger index = 0; index < stack.count && index < 8; index++) {
        UIViewController *controller = stack[index];
        for (UIViewController *child in controller.childViewControllers) {
            [stack addObject:child];
        }
    }

    for (UIViewController *controller in stack.reverseObjectEnumerator) {
        if (!controller.isViewLoaded) continue;
        UITableView *tableView = DPOFirstTableViewInView(controller.view, 0);
        if (tableView != nil && !tableView.hidden && tableView.window != nil) return tableView;
    }
    return nil;
}

void DPORunOnMain(dispatch_block_t block) {
    if (block == nil) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

#pragma mark - 拼音

NSString *DPOPinyinInitials(NSString *text) {
    if (text.length == 0) return @"";

    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
        lock = [[NSLock alloc] init];
    });

    [lock lock];
    NSString *cached = cache[text];
    [lock unlock];
    if (cached != nil) return cached;

    NSString *result = @"";
    @try {
        NSMutableString *mutable = [text mutableCopy];
        CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformToLatin, false);
        CFStringTransform((__bridge CFMutableStringRef)mutable, NULL, kCFStringTransformStripDiacritics, false);

        NSMutableString *initials = [NSMutableString string];
        NSArray<NSString *> *words = [mutable componentsSeparatedByCharactersInSet:
                                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        for (NSString *word in words) {
            if (word.length == 0) continue;
            [initials appendString:[word substringToIndex:1]];
        }
        result = [initials lowercaseString];
    } @catch (__unused NSException *exception) {
        result = @"";
    }

    if (result.length > 0) {
        [lock lock];
        if (cache.count > 4000) [cache removeAllObjects];
        cache[text] = result;
        [lock unlock];
    }
    return result;
}

#pragma mark - 其它

NSString *DPOPluginDisplayNameFromPath(NSString *path) {
    if (path.length == 0) return @"未知插件";

    NSString *name = nil;
    NSRange frameworkRange = [path rangeOfString:@".framework/"];
    if (frameworkRange.location != NSNotFound) {
        NSString *prefix = [path substringToIndex:frameworkRange.location];
        name = prefix.lastPathComponent;
    } else {
        name = path.lastPathComponent.stringByDeletingPathExtension;
    }
    if (name.length == 0) return @"未知插件";

    
    if ([name hasPrefix:@"lib"] && name.length > 3) {
        unichar c = [name characterAtIndex:3];
        if (c >= 'A' && c <= 'Z') name = [name substringFromIndex:3];
    }
    return name;
}

void DPOHapticImpact(UIImpactFeedbackStyle style) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DPOHapticImpact(style);
        });
        return;
    }
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [generator prepare];
    [generator impactOccurred];
}

void DPOHapticSelection(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DPOHapticSelection();
        });
        return;
    }
    UISelectionFeedbackGenerator *generator = [[UISelectionFeedbackGenerator alloc] init];
    [generator prepare];
    [generator selectionChanged];
}

NSString *DPOSafeString(id value) {
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if (value == nil || value == [NSNull null]) return @"";
    return [value description] ?: @"";
}
