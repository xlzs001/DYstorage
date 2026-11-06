

#import "DPOModel.h"
#import "DPORuntime.h"
#import "DPOTheme.h"

#import <errno.h>
#import <unistd.h>

NSString *const DPOPluginInfoDidUpdateNotification = @"DPOPluginInfoDidUpdateNotification";
NSString *const DPOStoreDidUpdateNotification = @"DPOStoreDidUpdateNotification";
NSString *const DPOFeatureStateDidChangeNotification = @"DPOFeatureStateDidChangeNotification";

static NSString *const DPODeepIndexDefaultsKey = @"DPODeepIndex.v2";
static NSString *const DPOStaticIndexDefaultsKey = @"DPOStaticIndex.v1";
static NSString *const DPODefaultsSuite = @"com.dpo.pluginnest";

#pragma mark - DPOPluginInfo

@implementation DPOPluginInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        _displayName = @"未知插件";
        _resolved = NO;
    }
    return self;
}

@end

#pragma mark - DPOFeature

@implementation DPOFeature {
    NSString *_searchBlob;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _locatorIndex = -1;
    }
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    [self refreshSearchBlob];
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitle = [subtitle copy];
    [self refreshSearchBlob];
}

- (void)setIdentifier:(NSString *)identifier {
    _identifier = [identifier copy];
    [self refreshSearchBlob];
}

- (void)setPluginName:(NSString *)pluginName {
    _pluginName = [pluginName copy];
    [self refreshSearchBlob];
}

- (void)setSectionTitle:(NSString *)sectionTitle {
    // sectionTitle 也参与 searchBlob，缺了这次刷新，先算过 blob 再补分组名的条目
    // 就永远搜不到分组名。
    _sectionTitle = [sectionTitle copy];
    [self refreshSearchBlob];
}

- (NSString *)searchBlob {
    if (_searchBlob == nil) [self refreshSearchBlob];
    return _searchBlob ?: @"";
}

- (void)refreshSearchBlob {
    NSMutableString *blob = [NSMutableString string];
    if (_title.length) [blob appendString:_title];
    if (_subtitle.length) [blob appendFormat:@" %@", _subtitle];
    if (_pluginName.length) [blob appendFormat:@" %@", _pluginName];
    if (_identifier.length) [blob appendFormat:@" %@", _identifier];
    if (_sectionTitle.length) [blob appendFormat:@" %@", _sectionTitle];

    NSString *initials = DPOPinyinInitials(_title);
    if (initials.length) [blob appendFormat:@" %@", initials];

    _searchBlob = [blob lowercaseString];
}

@end

#pragma mark - DPOPluginGroup

@implementation DPOPluginGroup

- (UIColor *)accentColor {
    NSUInteger seed = 0;
    for (NSUInteger i = 0; i < self.imagePath.length; i++) {
        seed = seed * 131 + [self.imagePath characterAtIndex:i];
    }
    NSArray<UIColor *> *colors = DPOAvatarColors((NSInteger)(seed % 6));
    return colors.firstObject ?: DPOColorAccent();
}

@end

#pragma mark - 搜索

static NSArray<NSString *> *DPOTokens(NSString *query) {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @[];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length == 0) continue;
        [tokens addObject:part.lowercaseString];
    }
    return tokens;
}

static NSInteger DPOScore(DPOFeature *feature, NSString *lowerQuery, NSArray<NSString *> *tokens) {
    if (feature == nil) return -1;
    NSString *blob = feature.searchBlob;
    for (NSString *token in tokens) {
        if (![blob containsString:token]) return -1;
    }

    NSString *title = feature.title.lowercaseString ?: @"";
    NSString *subtitle = feature.subtitle.lowercaseString ?: @"";
    NSString *plugin = feature.pluginName.lowercaseString ?: @"";
    NSString *initials = DPOPinyinInitials(feature.title);

    NSInteger score = 20;
    if ([title isEqualToString:lowerQuery]) score = 120;
    else if ([title hasPrefix:lowerQuery]) score = 100;
    else if ([title containsString:lowerQuery]) score = 80;
    else if ([initials hasPrefix:lowerQuery]) score = 70;
    else if ([plugin containsString:lowerQuery]) score = 45;
    else if ([subtitle containsString:lowerQuery]) score = 35;

    // 离线字符串只是「可能存在的功能」，排序永远让真正加载过的功能靠前。
    if (feature.isStatic) score = MAX((NSInteger)1, score - 30);
    return score;
}

NSArray<DPOFeature *> *DPOSearchFeatures(NSArray<DPOFeature *> *features, NSString *query) {
    NSArray<NSString *> *tokens = DPOTokens(query);
    if (tokens.count == 0 || features.count == 0) return @[];

    NSString *lowerQuery = [[query stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];

    NSMutableArray<DPOFeature *> *hits = [NSMutableArray array];
    
    
    NSMutableDictionary<NSValue *, NSNumber *> *scores = [NSMutableDictionary dictionary];

    for (DPOFeature *feature in features) {
        NSInteger score = DPOScore(feature, lowerQuery, tokens);
        if (score < 0) continue;
        [hits addObject:feature];
        scores[[NSValue valueWithNonretainedObject:feature]] = @(score);
    }

    [hits sortUsingComparator:^NSComparisonResult(DPOFeature *a, DPOFeature *b) {
        if (a.isStatic != b.isStatic) return a.isStatic ? NSOrderedDescending : NSOrderedAscending;
        NSInteger sa = scores[[NSValue valueWithNonretainedObject:a]].integerValue;
        NSInteger sb = scores[[NSValue valueWithNonretainedObject:b]].integerValue;
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        return [a.title localizedStandardCompare:b.title];
    }];
    return hits;
}

NSRange DPOMatchRangeInString(NSString *string, NSString *query) {
    if (string.length == 0) return NSMakeRange(NSNotFound, 0);
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NSMakeRange(NSNotFound, 0);
    return [string rangeOfString:trimmed options:NSCaseInsensitiveSearch];
}

#pragma mark - 安装状态

BOOL DPOPluginImageInstalled(NSString *image) {
    if (image.length == 0) return NO;

    static NSMutableDictionary<NSString *, NSNumber *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    @synchronized (cache) {
        NSNumber *cached = cache[image];
        if (cached != nil) return cached.boolValue;
    }

    // 注意：这里只缓存「确定」的结果。抖音跑在沙盒里，stat /var/jb 下的路径可能
    // 直接返回 EACCES/EPERM，这不代表插件已被卸载；把它当成「不存在」会让深层
    // 索引被误删并且负结果被永久缓存（旧实现的问题），所以这种情况下按「未知」
    // 处理，返回 YES 且不写缓存。
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL exists = [manager fileExistsAtPath:image];
    if (!exists) {
        NSString *resolved = [image stringByResolvingSymlinksInPath];
        if (resolved.length > 0 && ![resolved isEqualToString:image]) {
            exists = [manager fileExistsAtPath:resolved];
        }
    }
    if (!exists) {
        const char *path = image.fileSystemRepresentation;
        if (path != NULL) {
            errno = 0;
            BOOL accessible = (access(path, F_OK) == 0);
            if (accessible) {
                exists = YES;
            } else if (errno != ENOENT && errno != ENOTDIR) {
                // 权限/沙盒错误：无法判断，返回「未知」且不缓存，等下次再查。
                return YES;
            }
        }
    }

    @synchronized (cache) {
        cache[image] = @(exists);
    }
    return exists;
}

NSString *DPOPluginIdentity(NSString *image) {
    if (image.length == 0) return @"";

    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    @synchronized (cache) {
        NSString *cached = cache[image];
        if (cached != nil) return cached;
        NSString *name = [image lastPathComponent];
        if (name.length == 0) name = image;
        NSString *identity = [name lowercaseString];
        cache[image] = identity;
        return identity;
    }
}

#pragma mark - DPOFeatureStore

@interface DPOFeatureStore ()
- (void)_loadDeepIndex;
- (void)_loadStaticIndex;
- (void)_persistDeepIndex;
- (void)_persistStaticIndex;
- (void)_schedulePersistDeepIndex;
@end

@implementation DPOFeatureStore {
    NSMutableArray<DPOPluginGroup *> *_groups;
    NSMutableArray<DPOFeature *> *_deepFeatures;
    NSMutableArray<DPOFeature *> *_staticFeatures;
    NSUserDefaults *_defaults;
    NSString *_lastGroupsSignature;
    BOOL _persistScheduled;
}

+ (instancetype)shared {
    static DPOFeatureStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[DPOFeatureStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _groups = [NSMutableArray array];
        _deepFeatures = [NSMutableArray array];
        _staticFeatures = [NSMutableArray array];
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:DPODefaultsSuite] ?: [NSUserDefaults standardUserDefaults];
        // 1.1.46 起搜索恢复：必须把深层/静态索引读回来。
        // （1.1.38 搜索下线时这里会主动 removeObjectForKey + 从不加载，导致每次重启索引清零。）
        [self _loadDeepIndex];
        [self _loadStaticIndex];
    }
    return self;
}

- (void)_loadDeepIndex {
    NSArray *saved = [_defaults arrayForKey:DPODeepIndexDefaultsKey];
    if (![saved isKindOfClass:[NSArray class]]) return;

    // 不再按「文件是否存在」过滤：抖音沙盒里 stat /var/jb 可能被拒绝，
    // 过滤会把整份深层索引当成「插件已卸载」并立刻从磁盘删除（旧实现的误删问题）。
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *dict in saved) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        NSString *image = DPOSafeString(dict[@"p"]);
        NSString *title = DPOSafeString(dict[@"t"]);
        if (title.length == 0) continue;

        NSString *dedupe = [NSString stringWithFormat:@"%@|%@", image, title];
        if ([seen containsObject:dedupe]) continue;
        [seen addObject:dedupe];

        DPOFeature *feature = [[DPOFeature alloc] init];
        feature.pluginImage = image;
        feature.title = title;
        feature.subtitle = DPOSafeString(dict[@"d"]);
        feature.sectionTitle = DPOSafeString(dict[@"s"]);
        feature.isDeep = YES;
        feature.pluginName = DPOSafeString(dict[@"n"]);
        feature.locatorPage = DPOSafeString(dict[@"r"]);
        feature.locatorIndex = [dict[@"i"] respondsToSelector:@selector(integerValue)]
                                   ? [dict[@"i"] integerValue]
                                   : -1;
        // 落盘数据可能来自旧版本或被外部改写：元素必须逐项校验成 NSString，
        // 否则定位时把 NSNumber 当标题调 length 会直接 unrecognized selector。
        if ([dict[@"l"] isKindOfClass:[NSArray class]]) {
            NSMutableArray<NSString *> *trail = [NSMutableArray array];
            for (id step in (NSArray *)dict[@"l"]) {
                if ([step isKindOfClass:[NSString class]] && [step length] > 0) {
                    [trail addObject:step];
                }
            }
            feature.locatorTrail = trail.count > 0 ? [trail copy] : nil;
        }
        feature.key = [NSString stringWithFormat:@"deep|%@|%@", image, title];
        [feature refreshSearchBlob];
        [_deepFeatures addObject:feature];
    }

    // 旧版本没有 2000 上限，文件里可能比新上限多；保留最近的 2000 条。
    if (_deepFeatures.count > 2000) {
        [_deepFeatures removeObjectsInRange:NSMakeRange(0, _deepFeatures.count - 2000)];
    }
}

- (void)_persistDeepIndex {
    NSMutableArray *payload = [NSMutableArray arrayWithCapacity:_deepFeatures.count];
    for (DPOFeature *feature in _deepFeatures) {
        NSMutableDictionary *entry = [@{
            @"p": feature.pluginImage ?: @"",
            @"t": feature.title ?: @"",
            @"d": feature.subtitle ?: @"",
            @"s": feature.sectionTitle ?: @"",
            @"n": feature.pluginName ?: @"",
            @"i": @(feature.locatorIndex),
            @"r": feature.locatorPage ?: @"",
        } mutableCopy];
        if (feature.locatorTrail.count > 0) entry[@"l"] = feature.locatorTrail;
        [payload addObject:entry];
    }
    [_defaults setObject:payload forKey:DPODeepIndexDefaultsKey];
}

- (void)_schedulePersistDeepIndex {
    @synchronized (self) {
        if (_persistScheduled) return;
        _persistScheduled = YES;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @synchronized (self) {
            _persistScheduled = NO;
            [self _persistDeepIndex];
        }
    });
}

- (void)_persistStaticIndex {
    NSMutableArray *payload = [NSMutableArray arrayWithCapacity:_staticFeatures.count];
    for (DPOFeature *feature in _staticFeatures) {
        if (feature.pluginImage.length == 0 || feature.title.length == 0) continue;
        [payload addObject:@{
            @"p": feature.pluginImage,
            @"t": feature.title,
            @"n": feature.pluginName ?: @"",
        }];
    }
    [_defaults setObject:payload forKey:DPOStaticIndexDefaultsKey];
}

- (void)_loadStaticIndex {
    NSArray *saved = [_defaults arrayForKey:DPOStaticIndexDefaultsKey];
    if (![saved isKindOfClass:[NSArray class]]) return;

    // 同 _loadDeepIndex：不做文件存在性过滤，避免沙盒误判导致索引被清空。
    for (NSDictionary *dict in saved) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        NSString *image = DPOSafeString(dict[@"p"]);
        NSString *title = DPOSafeString(dict[@"t"]);
        if (image.length == 0 || title.length == 0) continue;

        DPOFeature *feature = [[DPOFeature alloc] init];
        feature.pluginImage = image;
        feature.title = title;
        feature.pluginName = DPOSafeString(dict[@"n"]);
        feature.isDeep = YES;
        feature.isStatic = YES;
        feature.key = [NSString stringWithFormat:@"static|%@|%@", image, title];
        [feature refreshSearchBlob];
        [_staticFeatures addObject:feature];
    }
}

#pragma mark - 静态索引

- (NSArray<DPOFeature *> *)staticFeatures {
    @synchronized (self) {
        return [_staticFeatures copy];
    }
}

- (NSUInteger)staticCount {
    @synchronized (self) {
        return _staticFeatures.count;
    }
}

- (void)replaceStaticFeatures:(NSArray<DPOFeature *> *)features {
    @synchronized (self) {
        [_staticFeatures removeAllObjects];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (DPOFeature *feature in features) {
            if (feature.title.length == 0 || feature.pluginImage.length == 0) continue;
            // 这些条目来自「已加载镜像」，必然存在；不再做文件存在性检查，
            // 避免沙盒拒绝 stat /var/jb 时把整个离线索引误删。
            NSString *dedupe = [NSString stringWithFormat:@"%@|%@",
                                feature.pluginImage, feature.title];
            if ([seen containsObject:dedupe]) continue;
            if (_staticFeatures.count >= 1200) break;
            [seen addObject:dedupe];

            feature.isDeep = YES;
            feature.isStatic = YES;
            feature.key = [NSString stringWithFormat:@"static|%@|%@",
                           feature.pluginImage, feature.title];
            [feature refreshSearchBlob];
            [_staticFeatures addObject:feature];
        }
    }

    // 落盘放到后台，避免一次性写上千条时卡住主线程。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @synchronized (self) {
            [self _persistStaticIndex];
        }
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DPOStoreDidUpdateNotification object:nil];
    });
}

- (DPOFeature *)liveFeatureForImage:(NSString *)image {
    if (image.length == 0) return nil;
    NSString *identity = DPOPluginIdentity(image);

    @synchronized (self) {
        for (DPOPluginGroup *group in _groups) {
            if (![DPOPluginIdentity(group.imagePath) isEqualToString:identity]) continue;
            for (DPOFeature *feature in group.features) {
                if (feature.item != nil) return feature;
            }
        }
        return nil;
    }
}



- (NSArray<DPOFeature *> *)deepFeatures {
    @synchronized (self) {
        return [_deepFeatures copy];
    }
}

- (NSArray<DPOPluginGroup *> *)groups {
    // 头文件里是 readonly，但底层 _groups 是可变数组，由 updateWithGroups: 就地替换。
    // 这里必须返回快照，否则调用方在枚举时正好被替换就会 mutation while enumerating。
    @synchronized (self) {
        return [_groups copy];
    }
}

- (NSUInteger)pluginCount {
    @synchronized (self) {
        return _groups.count;
    }
}

- (NSUInteger)featureCount {
    @synchronized (self) {
        NSUInteger count = 0;
        for (DPOPluginGroup *group in _groups) count += group.features.count;
        return count;
    }
}

- (NSUInteger)deepCount {
    @synchronized (self) {
        return _deepFeatures.count;
    }
}

- (void)updateWithGroups:(NSArray<DPOPluginGroup *> *)groups {
    if (groups == nil) return;

    
    
    NSMutableString *signature = [NSMutableString string];
    for (DPOPluginGroup *group in groups) {
        [signature appendFormat:@"%@|%@|", group.name ?: @"", group.version ?: @""];
        for (DPOFeature *feature in group.features) {
            NSString *state = feature.isSwitch ? (feature.isOn ? @"1" : @"0") : @"-";
            [signature appendFormat:@"%@,%@;", feature.key ?: @"", state];
        }
    }

    BOOL contentChanged = NO;
    @synchronized (self) {
        contentChanged = (_lastGroupsSignature == nil ||
                          ![signature isEqualToString:_lastGroupsSignature]);
        _lastGroupsSignature = [signature copy];

        
        
        
        
        
        [_groups removeAllObjects];
        [_groups addObjectsFromArray:groups];
    }

    if (!contentChanged) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DPOStoreDidUpdateNotification object:nil];
    });
}

- (void)setDeepFeatureCount:(NSUInteger)count forImage:(NSString *)image {
    if (image.length == 0) return;
    @synchronized (self) {
        // 只同步到已存在的分组上；分组不存在时等下次 updateWithGroups: 再算，
        // 不需要额外维护一份「镜像 → 条数」的字典（旧实现里那份字典从没被读过）。
        for (DPOPluginGroup *group in _groups) {
            if ([group.imagePath isEqualToString:image]) {
                group.deepFeatureCount = count;
            }
        }
    }
}

- (NSUInteger)deepFeatureCountForImage:(NSString *)image {
    if (image.length == 0) return 0;
    @synchronized (self) {
        NSUInteger count = 0;
        for (DPOFeature *feature in _deepFeatures) {
            if ([feature.pluginImage isEqualToString:image]) count += 1;
        }
        return count;
    }
}

- (void)mergeDeepFeatures:(NSArray<DPOFeature *> *)features {
    if (features.count == 0) return;

    BOOL changed = NO;
    @synchronized (self) {
        NSMutableSet<NSString *> *existing = [NSMutableSet set];
        for (DPOFeature *feature in _deepFeatures) {
            [existing addObject:[NSString stringWithFormat:@"%@|%@", feature.pluginImage, feature.title]];
        }

        for (DPOFeature *feature in features) {
            if (feature.title.length == 0) continue;
            NSString *dedupeKey = [NSString stringWithFormat:@"%@|%@", feature.pluginImage, feature.title];
            if ([existing containsObject:dedupeKey]) continue;
            [existing addObject:dedupeKey];
            [_deepFeatures addObject:feature];
            changed = YES;
        }

        // 1.1.48：从 600 提到 2000 —— 多了「看见即收录」这一路，
        // 逛两三个插件的子页就能把 600 撑满，老条目会被挤掉。
        if (_deepFeatures.count > 2000) {
            [_deepFeatures removeObjectsInRange:NSMakeRange(0, _deepFeatures.count - 2000)];
        }
        if (changed) {
            
            NSMutableSet<NSString *> *touchedImages = [NSMutableSet set];
            for (DPOFeature *feature in features) {
                if (feature.pluginImage.length > 0) [touchedImages addObject:feature.pluginImage];
            }
            for (DPOPluginGroup *group in _groups) {
                if (![touchedImages containsObject:group.imagePath]) continue;
                NSUInteger count = 0;
                for (DPOFeature *deep in _deepFeatures) {
                    if ([deep.pluginImage isEqualToString:group.imagePath]) count += 1;
                }
                group.deepFeatureCount = count;
            }
        }
    }

    if (changed) {
        // 落盘放后台并做 0.4s 合并：捕获是「边浏览边增长」的，旧实现每条
        // 新标题都整表写一次偏好，插件页首屏几十行就是几十次全量写。
        [self _schedulePersistDeepIndex];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DPOStoreDidUpdateNotification object:nil];
        });
    }
}

- (DPOFeature *)featureForKey:(NSString *)key {
    if (key.length == 0) return nil;
    @synchronized (self) {
        for (DPOPluginGroup *group in _groups) {
            for (DPOFeature *feature in group.features) {
                if ([feature.key isEqualToString:key]) return feature;
            }
        }
    }
    return nil;
}

- (NSArray<DPOFeature *> *)allSearchableFeatures {
    NSMutableArray<DPOFeature *> *all = [NSMutableArray array];

    NSArray<DPOPluginGroup *> *groups = self.groups;
    NSMutableSet<NSString *> *liveKeys = [NSMutableSet set];

    for (DPOPluginGroup *group in groups) {
        for (DPOFeature *feature in group.features) {
            [all addObject:feature];
            [liveKeys addObject:[NSString stringWithFormat:@"%@|%@",
                                 DPOPluginIdentity(feature.pluginImage), feature.title]];
        }
    }

    for (DPOFeature *feature in self.deepFeatures) {
        NSString *key = [NSString stringWithFormat:@"%@|%@",
                         DPOPluginIdentity(feature.pluginImage), feature.title];
        if ([liveKeys containsObject:key]) continue;
        [liveKeys addObject:key];
        [all addObject:feature];
    }

    // 离线静态索引：插件页从未打开过也能搜到。命中的条目点进去后按标题定位。
    for (DPOFeature *feature in self.staticFeatures) {
        NSString *key = [NSString stringWithFormat:@"%@|%@",
                         DPOPluginIdentity(feature.pluginImage), feature.title];
        if ([liveKeys containsObject:key]) continue;
        [liveKeys addObject:key];
        [all addObject:feature];
    }
    return all;
}

@end
