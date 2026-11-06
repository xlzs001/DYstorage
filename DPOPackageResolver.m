

#import "DPOPackageResolver.h"
#import "DPORuntime.h"
#import "DPOLogCenter.h"

static NSString *const DPOPackageCacheKey = @"DPOPackageCache.v1";
static NSString *const DPODefaultsSuite = @"com.dpo.pluginnest";
static NSString *const DPOOverridePath = @"/var/mobile/Library/Preferences/com.dpo.pluginnest.overrides.plist";

@interface DPOPackageResolver ()
- (void)_loadOverrides;
- (void)_ensureLoaded;
- (void)_parseStatusContent:(NSString *)content into:(NSMutableDictionary<NSString *, NSDictionary *> *)packages;
- (void)_commitStanza:(NSDictionary *)stanza into:(NSMutableDictionary<NSString *, NSDictionary *> *)packages;
- (NSString *)_cleanVersion:(NSString *)version;
- (void)_publishInfo:(DPOPluginInfo *)info forPath:(NSString *)path;
- (DPOPluginInfo *)_placeholderForPath:(NSString *)path;
- (void)_persistResolvedInfo:(DPOPluginInfo *)info;
- (void)_finishResolving:(DPOPluginInfo *)info;
@end

@implementation DPOPackageResolver {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, DPOPluginInfo *> *_cache;
    NSMutableSet<NSString *> *_pending;
    NSDictionary<NSString *, NSDictionary *> *_packages;   
    NSDictionary<NSString *, NSString *> *_fileOwners;     
    NSDictionary<NSString *, NSDictionary *> *_overrides;  
    NSUserDefaults *_defaults;
    BOOL _loaded;
}

+ (instancetype)shared {
    static DPOPackageResolver *resolver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resolver = [[DPOPackageResolver alloc] init];
    });
    return resolver;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.dpo.pluginnest.package", DISPATCH_QUEUE_SERIAL);
        _cache = [NSMutableDictionary dictionary];
        _pending = [NSMutableSet set];
        _packages = @{};
        _fileOwners = @{};
        _overrides = @{};
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:DPODefaultsSuite] ?: [NSUserDefaults standardUserDefaults];
        [self _loadPersistedCache];
        [self _loadOverrides];
    }
    return self;
}

#pragma mark - 对外

- (void)prewarm {
    dispatch_async(_queue, ^{
        [self _ensureLoaded];
    });
}

- (DPOPluginInfo *)infoForImagePath:(NSString *)path {
    if (path.length == 0) return nil;

    DPOPluginInfo *info = nil;
    BOOL needsResolve = NO;

    @synchronized (self) {
        info = _cache[path];
        if (info == nil) {
            info = [self _placeholderForPath:path];
            _cache[path] = info;
            needsResolve = YES;
        } else if (!info.resolved) {
            needsResolve = [_pending containsObject:path] ? NO : YES;
        }
        if (needsResolve) [_pending addObject:path];
    }

    if (needsResolve) {
        dispatch_async(_queue, ^{
            [self _resolvePath:path];
        });
    }
    return info;
}

#pragma mark - 占位 / 缓存

- (DPOPluginInfo *)_placeholderForPath:(NSString *)path {
    DPOPluginInfo *info = [[DPOPluginInfo alloc] init];
    info.imagePath = path;
    info.displayName = DPOPluginDisplayNameFromPath(path);

    NSDictionary *persisted = [_defaults dictionaryForKey:DPOPackageCacheKey][path];
    if ([persisted isKindOfClass:[NSDictionary class]]) {
        NSString *name = DPOSafeString(persisted[@"n"]);
        NSString *version = DPOSafeString(persisted[@"v"]);
        NSString *package = DPOSafeString(persisted[@"p"]);
        if (name.length) info.displayName = name;
        if (version.length) info.version = version;
        if (package.length) info.packageID = package;
    }
    return info;
}

- (void)_loadPersistedCache {
    NSDictionary *saved = [_defaults dictionaryForKey:DPOPackageCacheKey];
    if (![saved isKindOfClass:[NSDictionary class]]) return;

    @synchronized (self) {
        for (NSString *path in saved) {
            NSDictionary *entry = saved[path];
            if (![entry isKindOfClass:[NSDictionary class]]) continue;

            DPOPluginInfo *info = [[DPOPluginInfo alloc] init];
            info.imagePath = path;
            info.displayName = DPOSafeString(entry[@"n"]);
            info.version = DPOSafeString(entry[@"v"]);
            info.packageID = DPOSafeString(entry[@"p"]);
            if (info.displayName.length == 0) info.displayName = DPOPluginDisplayNameFromPath(path);
            info.resolved = (info.version.length > 0);
            _cache[path] = info;
        }
    }
}

- (void)_persistResolvedInfo:(DPOPluginInfo *)info {
    if (info.imagePath.length == 0) return;

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    NSDictionary *saved = [_defaults dictionaryForKey:DPOPackageCacheKey];
    if ([saved isKindOfClass:[NSDictionary class]]) [payload addEntriesFromDictionary:saved];

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    if (info.displayName.length) entry[@"n"] = info.displayName;
    if (info.version.length) entry[@"v"] = info.version;
    if (info.packageID.length) entry[@"p"] = info.packageID;
    payload[info.imagePath] = entry;

    [_defaults setObject:payload forKey:DPOPackageCacheKey];
}

#pragma mark - 解析

- (void)_resolvePath:(NSString *)path {
    [self _ensureLoaded];

    DPOPluginInfo *placeholder = nil;
    @synchronized (self) {
        placeholder = _cache[path];
        [_pending removeObject:path];
    }
    if (placeholder == nil) return;

    
    
    
    DPOPluginInfo *info = [[DPOPluginInfo alloc] init];
    info.imagePath = path;
    info.displayName = placeholder.displayName.length > 0
                           ? placeholder.displayName
                           : DPOPluginDisplayNameFromPath(path);
    info.version = placeholder.version;
    info.packageID = placeholder.packageID;

    NSString *basename = path.lastPathComponent;
    NSString *packageID = nil;

    
    NSDictionary *override = _overrides[basename];
    if ([override isKindOfClass:[NSDictionary class]]) {
        NSString *name = DPOSafeString(override[@"name"]);
        NSString *version = DPOSafeString(override[@"version"]);
        if (name.length) info.displayName = name;
        if (version.length) info.version = version;
        if (name.length || version.length) {
            info.packageID = DPOSafeString(override[@"package"]);
            info.resolved = YES;
            [self _publishInfo:info forPath:path];
            [self _finishResolving:info];
            return;
        }
    }

    
    packageID = _fileOwners[basename];
    if (packageID.length == 0) {
        NSString *stem = basename.stringByDeletingPathExtension.lowercaseString;
        for (NSString *candidate in _fileOwners) {
            NSString *candidateStem = candidate.stringByDeletingPathExtension.lowercaseString;
            if ([candidateStem isEqualToString:stem]) {
                packageID = _fileOwners[candidate];
                break;
            }
        }
    }

    
    if (packageID.length == 0) {
        NSString *stem = basename.stringByDeletingPathExtension.lowercaseString;
        for (NSString *candidate in _packages) {
            NSString *tail = [[candidate componentsSeparatedByString:@"."] lastObject].lowercaseString;
            if ([tail isEqualToString:stem]) {
                packageID = candidate;
                break;
            }
        }
    }

    NSDictionary *package = packageID.length ? _packages[packageID] : nil;
    if ([package isKindOfClass:[NSDictionary class]]) {
        NSString *name = DPOSafeString(package[@"name"]);
        NSString *version = DPOSafeString(package[@"version"]);
        if (name.length) info.displayName = name;
        if (version.length) info.version = version;
        info.packageID = packageID;
        info.resolved = YES;
    } else {
        
        info.resolved = YES;
    }

    [self _publishInfo:info forPath:path];
    [self _finishResolving:info];
}

- (void)_publishInfo:(DPOPluginInfo *)info forPath:(NSString *)path {
    if (info == nil || path.length == 0) return;
    @synchronized (self) {
        _cache[path] = info;
    }
}

- (void)_finishResolving:(DPOPluginInfo *)info {
    [self _persistResolvedInfo:info];

    DPOLogEvent(@"PKG", @"%@ → %@ v%@ (%@)",
                info.imagePath.lastPathComponent,
                info.displayName ?: @"?",
                info.version ?: @"未知",
                info.packageID ?: @"无包信息");

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DPOPluginInfoDidUpdateNotification
                                                            object:info];
    });
}

#pragma mark - dpkg 读取

- (void)_loadOverrides {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:DPOOverridePath];
    if ([plist isKindOfClass:[NSDictionary class]]) {
        _overrides = plist;
    }
}

- (void)_ensureLoaded {
    @synchronized (self) {
        if (_loaded) return;
    }

    NSArray<NSString *> *statusPaths = @[
        @"/var/jb/var/lib/dpkg/status",
        @"/var/jb/Library/dpkg/status",
        @"/var/lib/dpkg/status",
        @"/private/var/lib/dpkg/status",
    ];

    NSMutableDictionary<NSString *, NSDictionary *> *packages = [NSMutableDictionary dictionary];
    for (NSString *path in statusPaths) {
        NSString *content = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
        if (content.length == 0) continue;
        [self _parseStatusContent:content into:packages];
        if (packages.count > 0) break;
    }

    NSArray<NSString *> *infoDirs = @[
        @"/var/jb/var/lib/dpkg/info",
        @"/var/jb/Library/dpkg/info",
        @"/var/lib/dpkg/info",
        @"/private/var/lib/dpkg/info",
    ];

    NSMutableDictionary<NSString *, NSString *> *owners = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in infoDirs) {
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:NULL];
        if (files.count == 0) continue;

        for (NSString *file in files) {
            if (![file hasSuffix:@".list"]) continue;
            NSString *packageID = [file stringByDeletingPathExtension];
            NSString *fullPath = [dir stringByAppendingPathComponent:file];
            NSString *content = [NSString stringWithContentsOfFile:fullPath
                                                          encoding:NSUTF8StringEncoding
                                                             error:NULL];
            if (content.length == 0) continue;

            [content enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
                if (![line hasSuffix:@".dylib"]) return;
                NSString *basename = line.lastPathComponent;
                if (basename.length == 0) return;
                if (owners[basename] != nil) return;
                owners[basename] = packageID;
            }];
        }
        if (owners.count > 0) break;
    }

    // 扫描全部完成后才发布结果并置位 _loaded：旧实现先置 _loaded 再扫描，
    // 任何跨队列的第二次调用都会看到「已加载」却拿到空表。
    @synchronized (self) {
        _packages = packages;
        _fileOwners = owners;
        _loaded = YES;
    }

    DPOLogEvent(@"PKG", @"dpkg 扫描完成：%lu 个包 / %lu 条 dylib 归属",
                (unsigned long)packages.count, (unsigned long)owners.count);
}

- (void)_parseStatusContent:(NSString *)content into:(NSMutableDictionary<NSString *, NSDictionary *> *)packages {
    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    for (NSString *line in lines) {
        if (line.length == 0) {
            [self _commitStanza:current into:packages];
            [current removeAllObjects];
            continue;
        }
        if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) continue;

        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;

        NSString *key = [line substringToIndex:colon.location];
        NSString *value = [[line substringFromIndex:colon.location + 1]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (key.length && value.length) current[key] = value;
    }
    [self _commitStanza:current into:packages];
}

- (void)_commitStanza:(NSDictionary *)stanza into:(NSMutableDictionary<NSString *, NSDictionary *> *)packages {
    if (stanza.count == 0) return;
    NSString *packageID = DPOSafeString(stanza[@"Package"]);
    if (packageID.length == 0) return;

    NSString *name = DPOSafeString(stanza[@"Name"]);
    NSString *version = [self _cleanVersion:DPOSafeString(stanza[@"Version"])];
    if (name.length == 0) name = [[packageID componentsSeparatedByString:@"."] lastObject];

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    if (name.length) entry[@"name"] = name;
    if (version.length) entry[@"version"] = version;
    packages[packageID] = entry;
}

- (NSString *)_cleanVersion:(NSString *)version {
    if (version.length == 0) return @"";
    NSString *cleaned = version;
    NSRange colon = [cleaned rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        cleaned = [cleaned substringFromIndex:colon.location + 1];
    }
    return [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

@end
