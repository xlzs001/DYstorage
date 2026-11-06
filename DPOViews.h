

#import "DPOModel.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 功能行

@interface DPOFeatureCell : UITableViewCell

@property (nonatomic, copy, nullable) void (^onSwitchChange)(BOOL isOn);

@property (nonatomic, assign) BOOL cardStyle;

- (void)configureWithFeature:(DPOFeature *)feature
             showsPluginName:(BOOL)showsPluginName
                       query:(nullable NSString *)query;

@end

#pragma mark - 插件分组头

@interface DPOPluginHeaderView : UIView

- (void)configureWithGroup:(DPOPluginGroup *)group;

@end

#pragma mark - 插件卡片行（新版收纳页）

@interface DPOPluginGroupCell : UITableViewCell

@property (nonatomic, copy, nullable) void (^onOpen)(void);

- (void)configureWithGroup:(DPOPluginGroup *)group expanded:(BOOL)expanded;

@end

#pragma mark - 空状态

@interface DPOEmptyView : UIView

@property (nonatomic, copy, nullable) void (^onAction)(void);

- (void)configureWithSymbol:(NSString *)symbol title:(NSString *)title subtitle:(NSString *)subtitle;
- (void)setActionTitle:(nullable NSString *)title;

@end

#pragma mark - 轻提示


#pragma mark - 搜索结果行（参考 DYStorage 的样式）

@interface DPOResultCell : UITableViewCell

/// title：功能名；location：右侧灰字「插件 › 二级 › 三级」；query 用于高亮命中片段。
- (void)configureTitle:(nullable NSString *)title
              location:(nullable NSString *)location
             pluginName:(nullable NSString *)pluginName
                 query:(nullable NSString *)query
            firstInSet:(BOOL)firstInSet
             lastInSet:(BOOL)lastInSet;

@end

@interface DPOToast : NSObject

+ (void)show:(NSString *)message;

@end

#pragma mark - 清透玻璃弹窗

@interface DPOGlassPopup : NSObject

+ (void)showTitle:(NSString *)title message:(nullable NSString *)message;

@end

NS_ASSUME_NONNULL_END
