

#import "DPOCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface DPOLogCenter : NSObject

+ (instancetype)shared;

- (void)start;

- (void)log:(NSString *)category format:(NSString *)format, ... NS_FORMAT_FUNCTION(2, 3);

- (NSArray<NSString *> *)lines;
- (NSString *)text;

- (NSString *)filePath;

- (void)flush;

- (void)flushSync;
- (void)clear;

@end

#define DPOLogEvent(category, fmt, ...)                                         \
    [[DPOLogCenter shared] log:(category) format:(fmt), ##__VA_ARGS__]

NS_ASSUME_NONNULL_END
