

#import "DPOModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DPOPackageResolver : NSObject

+ (instancetype)shared;

- (DPOPluginInfo *)infoForImagePath:(NSString *)path;

- (void)prewarm;

@end

NS_ASSUME_NONNULL_END
