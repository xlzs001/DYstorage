

#import "DPOModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DPOHarvester : NSObject

+ (NSArray *)handleMainViewModel:(AWESettingBaseViewModel *)vm sections:(NSArray *)sections;

+ (void)openOrganizerFromViewModel:(nullable AWESettingBaseViewModel *)vm;

+ (void)activateFeature:(DPOFeature *)feature from:(nullable UIViewController *)host;

/// 搜索命中的落地：活入口直接执行；深层项先打开插件页，再按 locatorTrail 一级级
/// 钻到目标页、滚动到那一行并高亮。二级/三级菜单都走这一条。
+ (void)locateFeature:(DPOFeature *)feature from:(nullable UIViewController *)host;

/// 主设置页没有该插件入口时，按插件镜像里的 ViewController 类名直接打开它的设置页。
/// 返回 YES 表示已经推入 / 呈现了页面。
+ (BOOL)openPluginSettingsPageForImage:(NSString *)image from:(nullable UIViewController *)host;

+ (void)toggleFeature:(DPOFeature *)feature;

+ (void)setFeature:(DPOFeature *)feature enabled:(BOOL)enabled;

/// 运行时「看见即收录」：插件用自己的 TableView 画设置页时（不走抖音的
/// AWESettingSectionModel），靠类归属判定这一行属于谁，把标题补进深层索引。
/// 调用方负责节流；内部按 (镜像, 标题) 去重。
+ (void)captureSeenTitle:(nullable NSString *)title ownerImage:(nullable NSString *)image;

+ (void)forceRefreshFromViewModel:(AWESettingBaseViewModel *)vm;

+ (NSUInteger)lastScanCount;

+ (NSUInteger)harvestChangeCount;

+ (NSUInteger)countThirdPartyItemsInSections:(NSArray *)sections;

+ (NSUInteger)purgeThirdPartyItemsInSections:(NSArray *)sections;

+ (NSUInteger)collectAndRemoveThirdPartyItemsInSections:(NSArray *)sections;

+ (id)lastProcessedViewModel;
+ (NSArray *)lastProcessedSections;

+ (void)setForceNextHarvest:(BOOL)force;
+ (BOOL)hasBootstrapped;

+ (BOOL)isCollectedIdentifier:(NSString *)identifier;

+ (NSArray *)handleSubPageViewModel:(AWESettingBaseViewModel *)vm sections:(NSArray *)sections;

+ (void)recoverQuarantineIfNeeded;

+ (void)resetScanCache;

@end

NS_ASSUME_NONNULL_END
