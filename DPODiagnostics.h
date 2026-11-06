

#import "DPOCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface DPODiagnosticEntry : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *section;
@property (nonatomic, copy) NSString *owner;       
@property (nonatomic, copy) NSString *blockImage;  
@property (nonatomic, copy) NSString *classInfo;   
@property (nonatomic, copy) NSString *itemClass;   
@property (nonatomic, copy) NSString *decision;    
@end

@interface DPODiagnostics : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSArray<DPODiagnosticEntry *> *entries;
@property (nonatomic, readonly) NSUInteger collectedCount;
@property (nonatomic, copy) NSString *context;   

- (void)reset;
- (void)addEntry:(DPODiagnosticEntry *)entry;

- (NSString *)flushToDisk;

@end

@interface DPODiagnosticsViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
