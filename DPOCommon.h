

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <substrate.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 日志

FOUNDATION_EXPORT BOOL DPOLogEnabled(void);

#define DPOLog(fmt, ...)                                                        \
    do {                                                                        \
        if (DPOLogEnabled()) {                                                  \
            NSLog((@"[PluginNest] " fmt), ##__VA_ARGS__);                       \
        }                                                                       \
    } while (0)

FOUNDATION_EXPORT void DPOLogOnceMessage(NSString *message);

#define DPOLogOnce(fmt, ...)                                                    \
    do {                                                                        \
        if (DPOLogEnabled()) {                                                  \
            DPOLogOnceMessage([NSString stringWithFormat:(fmt), ##__VA_ARGS__]);\
        }                                                                       \
    } while (0)

#pragma mark - 常量

extern NSString *const DPOEntryIdentifier;
extern NSString *const DPOEntryTitle;

extern NSString *const DPOBuildVersion;

extern NSString *const DPOPluginInfoDidUpdateNotification;

extern NSString *const DPOStoreDidUpdateNotification;

extern NSString *const DPOFeatureStateDidChangeNotification;

#pragma mark - 抖音设置页模型（只声明，不引用类符号）

@interface AWESettingItemModel : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subTitle;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *iconImageName;
@property (nonatomic, copy) NSString *svgIconImageName;
@property (nonatomic, copy) NSString *cellControllerClass;
@property (nonatomic, copy) NSString *bizViewModelClass;
@property (nonatomic, assign) long long type;
@property (nonatomic, assign) long long cellType;
@property (nonatomic, assign) BOOL isSwitchOn;
@property (nonatomic, assign) BOOL isEnable;
@property (nonatomic, copy) void (^cellTappedBlock)(void);
@property (nonatomic, copy) void (^switchChangedBlock)(BOOL isOn);
- (void)refreshCell;
@end

@interface AWESettingSectionModel : NSObject
@property (nonatomic, copy) NSString *sectionHeaderTitle;
@property (nonatomic, assign) double sectionHeaderHeight;
@property (nonatomic, copy) NSString *sectionFooterTitle;
@property (nonatomic, assign) long long type;
@property (nonatomic, strong) NSArray *itemArray;
@end

@interface AWESettingBaseViewModel : NSObject
@property (nonatomic, strong) NSArray *sectionDataArray;
@property (nonatomic, weak) id controllerDelegate;
- (id)itemModelWithType:(long long)type;
@end

@interface AWESettingsViewModel : AWESettingBaseViewModel
@end

@interface AWESettingBaseViewController : UIViewController
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, readonly) AWESettingBaseViewModel *viewModel;
@end

NS_ASSUME_NONNULL_END
