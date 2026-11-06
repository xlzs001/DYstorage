

#import "DPOCommon.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT Class DPOLookupClass(const char *name);

FOUNDATION_EXPORT BOOL DPOClassIs(id obj, const char *name);

FOUNDATION_EXPORT BOOL DPOIsMainSettingsViewModel(id vm);

typedef NS_ENUM(NSInteger, DPOSettingsViewModelKind) {
    DPOSettingsViewModelKindUnknown = 0,   
    DPOSettingsViewModelKindMain,          
    DPOSettingsViewModelKindSubPage,       
};
FOUNDATION_EXPORT DPOSettingsViewModelKind DPOClassifySettingsViewModel(id vm);

FOUNDATION_EXPORT void DPOSetMainSettingsViewModel(id vm);

FOUNDATION_EXPORT BOOL DPOIsThirdPartyImage(NSString *path);

FOUNDATION_EXPORT NSString *_Nullable DPOPluginImageForBlock(id block);

FOUNDATION_EXPORT NSString *_Nullable DPOPluginImageForItem(AWESettingItemModel *item);

FOUNDATION_EXPORT BOOL DPOItemIsHostOwned(AWESettingItemModel *item);

/// 类所在镜像若属于第三方插件，返回镜像路径；宿主/系统/PluginNest 自身返回 nil。
/// 用于「不认识插件内部模型」时，靠类归属反推这一行是哪个插件画的。
FOUNDATION_EXPORT NSString *_Nullable DPOPluginImageForClass(Class cls);

FOUNDATION_EXPORT void DPOCaptureOwnerForObject(id object);
FOUNDATION_EXPORT NSString *_Nullable DPOAssociatedOwner(id object);

FOUNDATION_EXPORT UIWindow *DPOKeyWindow(void);

FOUNDATION_EXPORT UIViewController *DPOTopViewController(void);

/// 取一个 cell 上"看起来像功能名"的文本：textLabel → 最靠上的单行 UILabel → accessibilityLabel。
/// 插件自绘的 cell 不走抖音模型，只能从视图反读。
FOUNDATION_EXPORT NSString *_Nullable DPOCellTitle(UITableViewCell *cell);

/// 在当前可见视图层级里找最靠前的 UITableView（定位用）。
FOUNDATION_EXPORT UITableView *_Nullable DPOTopmostTableView(void);

FOUNDATION_EXPORT void DPORunOnMain(dispatch_block_t block);

FOUNDATION_EXPORT NSString *DPOPinyinInitials(NSString *text);

FOUNDATION_EXPORT NSString *DPOPluginDisplayNameFromPath(NSString *path);

FOUNDATION_EXPORT void DPOHapticImpact(UIImpactFeedbackStyle style);
FOUNDATION_EXPORT void DPOHapticSelection(void);

FOUNDATION_EXPORT NSString *DPOSafeString(id value);

NS_ASSUME_NONNULL_END
