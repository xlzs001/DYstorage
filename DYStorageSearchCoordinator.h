#import <Foundation/Foundation.h>

@class UIViewController;

typedef NSArray * _Nonnull (^DYStorageSearchSectionsProvider)(NSString * _Nonnull query);

/// Adds a DYYY-style pinned search field to the DYStorage settings page.
@interface DYStorageSearchCoordinator : NSObject

+ (instancetype _Nullable)installOnController:(UIViewController * _Nonnull)controller
                                     viewModel:(id _Nonnull)viewModel
                              sectionsProvider:(DYStorageSearchSectionsProvider _Nonnull)sectionsProvider;

- (void)refreshWithCurrentQuery;
- (void)updateLayout;
- (void)pageDidAppear;

/// Re-resolves colors after the host app or the system switches appearance.
- (void)hostAppearanceDidChange;
- (void)pageDidDisappear;

@end
