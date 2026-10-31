#import <Foundation/Foundation.h>

/// Merges the developer-reviewed static catalog with entries learned at runtime
/// from plug-in settings pages the user actually opened.
///
/// The static catalog only covers plug-ins scanned when it was generated, so a
/// freshly installed or updated tweak is invisible to search. Every time
/// DYStorage opens a captured plug-in page it records that page's section and
/// row titles, which is enough to make those features searchable without
/// shipping stale data or parsing another tweak's binary.
FOUNDATION_EXPORT NSArray<NSDictionary *> *DYStorageSearchCatalogMerged(void);

/// Stores [{section, title}] for one plug-in, deduplicated and capped.
FOUNDATION_EXPORT void DYStorageRuntimeIndexLearn(NSString *plugin, NSArray<NSDictionary *> *features);

/// Number of learned features for a plug-in, used for diagnostics.
FOUNDATION_EXPORT NSUInteger DYStorageRuntimeIndexFeatureCount(NSString *plugin);
