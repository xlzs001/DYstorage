

#import "DPOCommon.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 插件身份

@interface DPOPluginInfo : NSObject
@property (copy) NSString *imagePath;
@property (copy) NSString *displayName;
@property (copy) NSString *version;      
@property (copy) NSString *packageID;    
@property (assign) BOOL resolved;        
@end

#pragma mark - 功能

@interface DPOFeature : NSObject

@property (nonatomic, copy) NSString *key;          
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *sectionTitle;
@property (nonatomic, copy) NSString *pluginImage;
@property (nonatomic, copy) NSString *pluginName;
@property (nonatomic, copy) NSString *pluginVersion;

@property (nonatomic, strong, nullable) AWESettingItemModel *item;   
@property (nonatomic, weak, nullable) AWESettingBaseViewModel *viewModel;

@property (nonatomic, assign) BOOL isSwitch;
@property (nonatomic, assign) BOOL isOn;
@property (nonatomic, assign) BOOL isDeep;          

/// 仅来自插件二进制静态扫描（页面还没打开过），用于「搜得到、点进去再定位」。
@property (nonatomic, assign) BOOL isStatic;

@property (nonatomic, copy, nullable) NSString *locatorPage;
@property (nonatomic, assign) NSInteger locatorIndex;

@property (nonatomic, copy, nullable) NSArray<NSString *> *locatorTrail;

@property (nonatomic, readonly) NSString *searchBlob;   

- (void)refreshSearchBlob;

@end

#pragma mark - 插件分组

@interface DPOPluginGroup : NSObject
@property (nonatomic, copy) NSString *imagePath;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *packageID;
@property (nonatomic, copy) NSString *iconName;   
@property (nonatomic, assign) NSUInteger deepFeatureCount;   
@property (nonatomic, copy) NSArray<DPOFeature *> *features;
@property (nonatomic, readonly) UIColor *accentColor;
@end

#pragma mark - 仓库

@interface DPOFeatureStore : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSArray<DPOPluginGroup *> *groups;
@property (nonatomic, readonly) NSArray<DPOFeature *> *deepFeatures;
/// 插件二进制静态扫描出来的功能名（未打开过页面也能搜到）。
@property (nonatomic, readonly) NSArray<DPOFeature *> *staticFeatures;

@property (nonatomic, readonly) NSUInteger pluginCount;
@property (nonatomic, readonly) NSUInteger featureCount;
@property (nonatomic, readonly) NSUInteger deepCount;
@property (nonatomic, readonly) NSUInteger staticCount;

- (void)updateWithGroups:(NSArray<DPOPluginGroup *> *)groups;

- (void)mergeDeepFeatures:(NSArray<DPOFeature *> *)features;

/// 整批替换静态索引（按插件分组扫描结果）。
- (void)replaceStaticFeatures:(NSArray<DPOFeature *> *)features;

/// 取某插件当前「活」的入口项（item 可用，能真正打开插件页）。
- (nullable DPOFeature *)liveFeatureForImage:(NSString *)image;

- (void)setDeepFeatureCount:(NSUInteger)count forImage:(NSString *)image;
- (NSUInteger)deepFeatureCountForImage:(NSString *)image;

- (nullable DPOFeature *)featureForKey:(NSString *)key;

- (NSArray<DPOFeature *> *)allSearchableFeatures;

@end

#pragma mark - 安装状态

FOUNDATION_EXPORT BOOL DPOPluginImageInstalled(NSString *image);

FOUNDATION_EXPORT NSString *DPOPluginIdentity(NSString *image);

#pragma mark - 搜索

FOUNDATION_EXPORT NSArray<DPOFeature *> *DPOSearchFeatures(NSArray<DPOFeature *> *features, NSString *query);

FOUNDATION_EXPORT NSRange DPOMatchRangeInString(NSString *string, NSString *query);

NS_ASSUME_NONNULL_END
