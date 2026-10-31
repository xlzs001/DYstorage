#import "DYStorageRuntimeIndex.h"

#import "DYStorageSearchCatalog.h"

static NSString *const kDYStorageRuntimeCatalogKey = @"DYStorageRuntimeCatalogV1";
static const NSUInteger kDYStorageRuntimeMaximumFeatures = 400;

static NSString *DYStorageRuntimeNormalized(id value) {
    if ([value isKindOfClass:[NSString class]] == NO) return nil;
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static NSMutableDictionary *DYStorageRuntimeCatalog(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kDYStorageRuntimeCatalogKey];
    return [stored isKindOfClass:[NSMutableDictionary class]] ? stored : [NSMutableDictionary dictionary];
}

static NSArray<NSDictionary *> *DYStorageRuntimeFeatures(NSString *plugin) {
    if (plugin.length == 0) return @[];
    NSDictionary *stored = DYStorageRuntimeCatalog()[plugin];
    NSArray *features = stored[@"features"];
    return [features isKindOfClass:[NSArray class]] ? features : @[];
}

void DYStorageRuntimeIndexLearn(NSString *plugin, NSArray<NSDictionary *> *features) {
    NSString *name = DYStorageRuntimeNormalized(plugin);
    if (name.length == 0 || [features isKindOfClass:[NSArray class]] == NO || features.count == 0) return;

    NSMutableArray *merged = [DYStorageRuntimeFeatures(name) mutableCopy];
    NSMutableSet<NSString *> *titles = [NSMutableSet set];
    for (NSDictionary *feature in merged) {
        NSString *title = DYStorageRuntimeNormalized(feature[@"title"]);
        if (title.length) [titles addObject:title];
    }

    for (NSDictionary *feature in features) {
        NSString *title = DYStorageRuntimeNormalized(feature[@"title"]);
        if (title.length == 0 || [titles containsObject:title]) continue;
        NSString *section = DYStorageRuntimeNormalized(feature[@"section"]) ?: @"";
        [merged addObject:@{ @"section": section, @"title": title }];
        [titles addObject:title];
        if (merged.count >= kDYStorageRuntimeMaximumFeatures) break;
    }

    NSMutableDictionary *catalog = DYStorageRuntimeCatalog();
    catalog[name] = @{ @"features": merged,
                       @"updated": @([[NSDate date] timeIntervalSince1970]) };
    [[NSUserDefaults standardUserDefaults] setObject:catalog forKey:kDYStorageRuntimeCatalogKey];
}

NSUInteger DYStorageRuntimeIndexFeatureCount(NSString *plugin) {
    NSString *name = DYStorageRuntimeNormalized(plugin);
    return name.length ? DYStorageRuntimeFeatures(name).count : 0;
}

NSArray<NSDictionary *> *DYStorageSearchCatalogMerged(void) {
    NSArray<NSDictionary *> *staticCatalog = DYStorageSearchCatalog();
    NSDictionary *learned = DYStorageRuntimeCatalog();
    if (learned.count == 0) return staticCatalog;

    NSMutableArray<NSDictionary *> *merged = [NSMutableArray array];
    NSMutableSet<NSString *> *covered = [NSMutableSet set];

    for (NSDictionary *entry in staticCatalog) {
        NSString *plugin = DYStorageRuntimeNormalized(entry[@"plugin"]);
        NSMutableArray *features = [entry[@"features"] mutableCopy] ?: [NSMutableArray array];
        NSMutableSet<NSString *> *titles = [NSMutableSet set];
        for (NSDictionary *feature in features) {
            NSString *title = DYStorageRuntimeNormalized(feature[@"title"]);
            if (title.length) [titles addObject:title];
        }
        for (NSDictionary *feature in DYStorageRuntimeFeatures(plugin)) {
            NSString *title = DYStorageRuntimeNormalized(feature[@"title"]);
            if (title.length == 0 || [titles containsObject:title]) continue;
            [features addObject:feature];
            [titles addObject:title];
        }
        NSMutableDictionary *updated = [entry mutableCopy];
        updated[@"features"] = features;
        [merged addObject:updated];
        if (plugin.length) [covered addObject:plugin];
    }

    for (NSString *plugin in learned) {
        if ([covered containsObject:plugin]) continue;
        NSArray<NSDictionary *> *features = DYStorageRuntimeFeatures(plugin);
        if (features.count == 0) continue;
        [merged addObject:@{ @"plugin": plugin,
                             @"aliases": @[ plugin ],
                             @"features": features,
                             @"learned": @YES }];
    }
    return merged;
}
