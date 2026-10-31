#import "DYStorageSearchCoordinator.h"

#import <UIKit/UIKit.h>
#import <math.h>

static UITableView *DYStorageSearchFindTableView(UIView *view, NSInteger depth) {
    if (!view || depth < 0) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *tableView = DYStorageSearchFindTableView(subview, depth - 1);
        if (tableView) return tableView;
    }
    return nil;
}

static BOOL DYStorageSearchSetValue(id object, id value, NSString *key) {
    if (!object || key.length == 0) return NO;
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

@interface DYStorageSearchCoordinator () <UITextFieldDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) id viewModel;
@property (nonatomic, weak) UITableView *tableView;
@property (nonatomic, copy) DYStorageSearchSectionsProvider sectionsProvider;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UITextField *searchTextField;
@property (nonatomic) UIEdgeInsets originalContentInset;
@property (nonatomic) UIEdgeInsets originalIndicatorInset;
@property (nonatomic) BOOL installedInsets;
@property (nonatomic) NSUInteger pendingSearchGeneration;
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, strong) UIPanGestureRecognizer *searchBackGestureRecognizer;
@property (nonatomic) BOOL previousInteractivePopGestureEnabled;
@property (nonatomic) BOOL hasStoredInteractivePopGestureEnabled;
@property (nonatomic) BOOL handlingSearchBackGesture;
@property (nonatomic) BOOL pageVisible;
@property (nonatomic, copy) NSArray<UIGestureRecognizer *> *suppressedNavigationGestures;
@property (nonatomic, copy) NSArray<NSNumber *> *suppressedNavigationGestureStates;
- (BOOL)installSearchHeader;
- (NSString *)trimmedQuery;
- (BOOL)isSearchInteractionActive;
- (BOOL)isTopController;
- (void)applyHostAppearance;
- (BOOL)hostPrefersDarkAppearance;
- (void)updateSupplementaryViewsForQuery:(NSString *)query;
- (void)applyFooterInset:(BOOL)searching footer:(UIView *)footer;
- (void)installNavigationInterceptors;
- (void)updateNavigationGestureState;
- (void)restoreNavigationGestureState;
- (BOOL)handleBackNavigationRequest;
- (void)handleSearchBackGesture:(UIPanGestureRecognizer *)gestureRecognizer;
- (void)searchTextDidChange:(UITextField *)textField;
@end

@implementation DYStorageSearchCoordinator

+ (instancetype)installOnController:(UIViewController *)controller
                            viewModel:(id)viewModel
                     sectionsProvider:(DYStorageSearchSectionsProvider)sectionsProvider {
    if (!controller || !viewModel || !sectionsProvider) return nil;
    DYStorageSearchCoordinator *coordinator = [[self alloc] init];
    coordinator.controller = controller;
    coordinator.viewModel = viewModel;
    coordinator.sectionsProvider = sectionsProvider;
    if (![coordinator installSearchHeader]) return nil;
    return coordinator;
}

- (BOOL)installSearchHeader {
    [self.controller view];
    UITableView *tableView = DYStorageSearchFindTableView(self.controller.view, 8);
    if (!tableView) return NO;
    self.tableView = tableView;

    CGFloat width = MAX(CGRectGetWidth(tableView.bounds), CGRectGetWidth(self.controller.view.bounds));
    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(width, 0), 52)];
    self.headerView.backgroundColor = UIColor.clearColor;
    self.headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.containerView = [[UIView alloc] initWithFrame:CGRectMake(16, 4, MAX(width - 32, 0), 44)];
    self.containerView.layer.cornerRadius = 12;
    self.containerView.layer.masksToBounds = NO;
    self.containerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.headerView addSubview:self.containerView];

    self.searchTextField = [[UITextField alloc] initWithFrame:self.containerView.bounds];
    self.searchTextField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.searchTextField.backgroundColor = UIColor.clearColor;
    self.searchTextField.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    self.searchTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchTextField.returnKeyType = UIReturnKeySearch;
    self.searchTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchTextField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.searchTextField.delegate = self;
    self.searchTextField.accessibilityLabel = @"DYStorage聚合搜索";
    self.searchTextField.placeholder = @"搜索设置项";

    UIView *leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 38, 30)];
    UIImageView *leftIcon = [[UIImageView alloc] initWithFrame:CGRectMake(14, 6, 18, 18)];
    leftIcon.image = [UIImage systemImageNamed:@"magnifyingglass"];
    leftIcon.contentMode = UIViewContentModeScaleAspectFit;
    leftIcon.tintColor = UIColor.secondaryLabelColor;
    [leftView addSubview:leftIcon];
    self.searchTextField.leftView = leftView;
    // Keep a stable text origin while editing. Switching the left icon on
    // after the first character moved both the insertion caret and text.
    self.searchTextField.leftViewMode = UITextFieldViewModeAlways;
    [self.searchTextField addTarget:self action:@selector(searchTextDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.containerView addSubview:self.searchTextField];

    self.containerView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.containerView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.containerView.layer.shadowOpacity = 0.08;
    self.containerView.layer.shadowOffset = CGSizeMake(0, 3);
    self.containerView.layer.shadowRadius = 3.5;
    self.searchTextField.textColor = UIColor.labelColor;
    self.searchTextField.tintColor = UIColor.systemBlueColor;

    [self.controller.view addSubview:self.headerView];
    self.originalContentInset = tableView.contentInset;
    self.originalIndicatorInset = tableView.scrollIndicatorInsets;
    UIEdgeInsets contentInset = tableView.contentInset;
    contentInset.top += CGRectGetHeight(self.headerView.bounds);
    tableView.contentInset = contentInset;
    UIEdgeInsets indicatorInset = tableView.scrollIndicatorInsets;
    indicatorInset.top += CGRectGetHeight(self.headerView.bounds);
    tableView.scrollIndicatorInsets = indicatorInset;
    self.installedInsets = YES;
    [self installNavigationInterceptors];
    [self updateLayout];
    [self applyHostAppearance];
    return YES;
}

- (NSString *)trimmedQuery {
    return [self.searchTextField.text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)isSearchInteractionActive {
    return self.searchTextField.isFirstResponder || [self trimmedQuery].length > 0;
}

- (BOOL)isTopController {
    UIViewController *controller = self.controller;
    if (!self.pageVisible || !controller.viewIfLoaded.window) return NO;
    UINavigationController *navigationController = controller.navigationController;
    if (!navigationController) return YES;
    UIViewController *visibleController = navigationController.visibleViewController ?:
                                          navigationController.topViewController;
    for (UIViewController *candidate = controller; candidate; candidate = candidate.parentViewController) {
        if (candidate == visibleController) return YES;
    }
    return NO;
}

- (void)installNavigationInterceptors {
    UIViewController *controller = self.controller;
    if (!controller) return;

    UINavigationController *navigationController = controller.navigationController;
    if (self.navigationController != navigationController) {
        [self restoreNavigationGestureState];
        [self.searchBackGestureRecognizer.view removeGestureRecognizer:self.searchBackGestureRecognizer];
        self.navigationController = navigationController;
    }

    if (!self.searchBackGestureRecognizer) {
        UIPanGestureRecognizer *gestureRecognizer =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleSearchBackGesture:)];
        gestureRecognizer.maximumNumberOfTouches = 1;
        gestureRecognizer.cancelsTouchesInView = YES;
        gestureRecognizer.delegate = self;
        gestureRecognizer.enabled = NO;
        self.searchBackGestureRecognizer = gestureRecognizer;
    }
    UIView *gestureHost = navigationController.view ?: controller.view;
    if (gestureHost && self.searchBackGestureRecognizer.view != gestureHost) {
        [self.searchBackGestureRecognizer.view removeGestureRecognizer:self.searchBackGestureRecognizer];
        [gestureHost addGestureRecognizer:self.searchBackGestureRecognizer];
    }
    [self updateNavigationGestureState];
}

- (void)updateNavigationGestureState {
    UINavigationController *navigationController = self.controller.navigationController;
    UIGestureRecognizer *interactivePopGesture = navigationController.interactivePopGestureRecognizer;
    BOOL shouldIntercept = [self isTopController] &&
        (self.handlingSearchBackGesture || [self isSearchInteractionActive]);

    self.searchBackGestureRecognizer.enabled = shouldIntercept;
    if (shouldIntercept) {
        if (!self.hasStoredInteractivePopGestureEnabled && interactivePopGesture) {
            self.previousInteractivePopGestureEnabled = interactivePopGesture.enabled;
            self.hasStoredInteractivePopGestureEnabled = YES;
        }
        if (!self.suppressedNavigationGestures.count) {
            NSMutableArray<UIGestureRecognizer *> *gestures = [NSMutableArray array];
            NSMutableArray<NSNumber *> *states = [NSMutableArray array];
            for (UIGestureRecognizer *gesture in navigationController.view.gestureRecognizers) {
                if (gesture == self.searchBackGestureRecognizer ||
                    ![gesture isKindOfClass:[UIPanGestureRecognizer class]]) continue;
                [gestures addObject:gesture];
                [states addObject:@(gesture.enabled)];
                gesture.enabled = NO;
            }
            self.suppressedNavigationGestures = gestures;
            self.suppressedNavigationGestureStates = states;
        }
        interactivePopGesture.enabled = NO;
    } else {
        [self restoreNavigationGestureState];
    }
}

- (void)restoreNavigationGestureState {
    NSUInteger stateCount = self.suppressedNavigationGestureStates.count;
    [self.suppressedNavigationGestures enumerateObjectsUsingBlock:^(UIGestureRecognizer *gesture,
                                                                    NSUInteger index,
                                                                    __unused BOOL *stop) {
        if (index < stateCount) gesture.enabled = self.suppressedNavigationGestureStates[index].boolValue;
    }];
    self.suppressedNavigationGestures = nil;
    self.suppressedNavigationGestureStates = nil;
    if (self.hasStoredInteractivePopGestureEnabled) {
        self.navigationController.interactivePopGestureRecognizer.enabled =
            self.previousInteractivePopGestureEnabled;
        self.hasStoredInteractivePopGestureEnabled = NO;
    }
    self.searchBackGestureRecognizer.enabled = NO;
}

- (BOOL)handleBackNavigationRequest {
    if (![self isTopController] || ![self isSearchInteractionActive]) return NO;

    // The first horizontal back swipe exits search and restores the complete hub.
    // A following swipe is handled by UINavigationController and returns to
    // Douyin settings, matching the two visible page levels.
    ++self.pendingSearchGeneration;
    self.searchTextField.text = @"";
    [self.searchTextField resignFirstResponder];
    [self refreshWithCurrentQuery];
    [self updateNavigationGestureState];
    return YES;
}

- (void)handleSearchBackGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    switch (gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan:
            // Keep the system pop gesture disabled until this complete touch
            // sequence ends. Re-enabling it while the finger was still moving
            // allowed the same swipe to clear search and pop the hub at once.
            self.handlingSearchBackGesture = YES;
            if (![self handleBackNavigationRequest]) {
                self.handlingSearchBackGesture = NO;
                [self updateNavigationGestureState];
            }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.handlingSearchBackGesture = NO;
            __weak DYStorageSearchCoordinator *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf updateNavigationGestureState];
            });
            break;
        }
        default:
            break;
    }
}

- (void)updateSupplementaryViewsForQuery:(NSString *)query {
    BOOL searching = query.length > 0;
    UIView *footer = nil;
    for (UIView *subview in self.controller.view.subviews) {
        if ([subview.accessibilityIdentifier isEqualToString:@"DYStorageAboutFooter"]) {
            subview.hidden = searching;
            footer = subview;
            break;
        }
    }
    [self applyFooterInset:searching footer:footer];
}

/// The about footer reserves 112pt of bottom inset while it is visible. Hiding
/// it during a search without releasing that inset left a blank strip under
/// the last result, so the reserved space follows the footer's real height.
- (void)applyFooterInset:(BOOL)searching footer:(UIView *)footer {
    UITableView *tableView = self.tableView;
    if (tableView == nil || self.installedInsets == NO) return;

    CGFloat footerHeight = footer ? CGRectGetHeight(footer.bounds) : 0;
    if (footer && footerHeight <= 0) footerHeight = 112;

    UIEdgeInsets inset = self.originalContentInset;
    if (searching && footerHeight > 0 && inset.bottom > 0) {
        inset.bottom = MAX(0, inset.bottom - footerHeight);
    }
    if (UIEdgeInsetsEqualToEdgeInsets(tableView.contentInset, inset)) return;

    tableView.contentInset = inset;
    UIEdgeInsets indicatorInset = self.originalIndicatorInset;
    if (searching && footerHeight > 0 && indicatorInset.bottom > 0) {
        indicatorInset.bottom = MAX(0, indicatorInset.bottom - footerHeight);
    }
    tableView.scrollIndicatorInsets = indicatorInset;
}

- (void)refreshWithCurrentQuery {
    if (!self.sectionsProvider || !self.viewModel) return;
    NSString *query = [self trimmedQuery];
    [self updateSupplementaryViewsForQuery:query];
    NSArray *sections = self.sectionsProvider(query) ?: @[];
    if (!DYStorageSearchSetValue(self.viewModel, sections, @"sectionDataArray")) return;
    UITableView *tableView = self.tableView;
    [tableView reloadData];
}

- (void)searchTextDidChange:(__unused UITextField *)textField {
    [self updateSupplementaryViewsForQuery:[self trimmedQuery]];
    [self updateNavigationGestureState];
    // Building native private-setting models for hundreds of catalog entries
    // is deliberately kept off the per-keystroke hot path. Coalesce rapid
    // edits so only the final query refreshes the table.
    NSUInteger generation = ++self.pendingSearchGeneration;
    __weak DYStorageSearchCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DYStorageSearchCoordinator *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.pendingSearchGeneration) return;
        if (![strongSelf isTopController]) return;
        [strongSelf refreshWithCurrentQuery];
    });
}

- (void)updateLayout {
    UITableView *tableView = self.tableView;
    if (!tableView || !self.headerView) return;
    UIView *superview = tableView.superview;
    if (!superview) return;
    CGRect tableFrame = [superview convertRect:tableView.frame toView:self.controller.view];
    CGFloat automaticTopInset = MAX(0, tableView.adjustedContentInset.top - tableView.contentInset.top);
    CGFloat width = CGRectGetWidth(tableView.bounds);
    CGRect headerFrame = CGRectMake(CGRectGetMinX(tableFrame),
                                    CGRectGetMinY(tableFrame) + automaticTopInset,
                                    width,
                                    52);
    CGRect containerFrame = CGRectMake(16, 4, MAX(width - 32, 0), 44);
    BOOL headerChanged = !CGRectEqualToRect(self.headerView.frame, headerFrame);
    BOOL containerChanged = !CGRectEqualToRect(self.containerView.frame, containerFrame) ||
                            self.containerView.layer.shadowPath == NULL;

    if (headerChanged) self.headerView.frame = headerFrame;
    if (containerChanged) {
        self.containerView.frame = containerFrame;
        self.containerView.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:self.containerView.bounds cornerRadius:12].CGPath;
        self.searchTextField.frame = self.containerView.bounds;
    }

    // Reordering a subview on every layout pass can itself schedule additional
    // layout work on some Douyin versions. Only reorder when another injected
    // view has actually covered the search header.
    if (self.headerView.superview == self.controller.view &&
        self.controller.view.subviews.lastObject != self.headerView) {
        [self.controller.view bringSubviewToFront:self.headerView];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(__unused UITextField *)textField {
    [self updateNavigationGestureState];
}

- (void)textFieldDidEndEditing:(__unused UITextField *)textField {
    [self updateNavigationGestureState];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.searchBackGestureRecognizer) {
        if (![self isTopController] || ![self isSearchInteractionActive]) return NO;
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:gestureRecognizer.view];
        return fabs(velocity.x) > fabs(velocity.y) * 1.15;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.searchBackGestureRecognizer) return YES;
    UIView *touchView = touch.view;
    if (!touchView) return NO;
    BOOL inSearchHeader = self.headerView &&
        (touchView == self.headerView || [touchView isDescendantOfView:self.headerView]);
    BOOL inSourceTable = self.tableView &&
        (touchView == self.tableView || [touchView isDescendantOfView:self.tableView]);
    // Floating plug-ins may draw directly above the DYStorage controller without
    // presenting another UIViewController. Ignore touches from those overlays
    // so the organizer's full-width back gesture cannot swallow their controls.
    return inSearchHeader || inSourceTable;
}

- (void)pageDidAppear {
    self.pageVisible = YES;
    [self installNavigationInterceptors];
    [self updateNavigationGestureState];
}

- (void)pageDidDisappear {
    ++self.pendingSearchGeneration;
    self.pageVisible = NO;
    self.handlingSearchBackGesture = NO;
    [self restoreNavigationGestureState];
}

- (void)dealloc {
    ++_pendingSearchGeneration;
    [self restoreNavigationGestureState];
    [_searchBackGestureRecognizer.view removeGestureRecognizer:_searchBackGestureRecognizer];
    [_searchTextField removeTarget:self action:@selector(searchTextDidChange:) forControlEvents:UIControlEventEditingChanged];
    UITableView *tableView = self.tableView;
    if (tableView && self.installedInsets) {
        tableView.contentInset = self.originalContentInset;
        tableView.scrollIndicatorInsets = self.originalIndicatorInset;
    }
}


#pragma mark - Host appearance

// Douyin ships its own light/dark switch on top of iOS appearance, so the
// system semantic colors this header used to rely on can end up as dark text on
// a dark host background. Resolve the host background instead: it is the only
// value that reflects what the user actually sees behind the field.
- (BOOL)hostPrefersDarkAppearance {
    UIColor *background = self.tableView.backgroundColor;
    if (background == nil || CGColorGetAlpha(background.CGColor) < 0.05) {
        background = self.controller.view.backgroundColor;
    }
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (background != nil && [background getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
        return luminance < 0.5;
    }
    return self.controller.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

- (void)applyHostAppearance {
    if (self.containerView == nil) return;
    BOOL dark = [self hostPrefersDarkAppearance];
    NSString *placeholder = self.searchTextField.attributedPlaceholder.string ?: self.searchTextField.placeholder;
    if (placeholder.length == 0) placeholder = self.searchTextField.accessibilityLabel;

    UIColor *textColor = dark ? UIColor.whiteColor : UIColor.labelColor;
    UIColor *placeholderColor = dark ? [UIColor colorWithWhite:1.0 alpha:0.45] : UIColor.placeholderTextColor;
    self.searchTextField.textColor = textColor;
    self.searchTextField.tintColor = dark ? UIColor.whiteColor : UIColor.systemBlueColor;

    if (dark) {
        self.containerView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        self.containerView.layer.shadowOpacity = 0.0;
    } else {
        self.containerView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.containerView.layer.shadowOpacity = 0.08;
    }

    UIImageView *icon = nil;
    for (UIView *subview in self.searchTextField.leftView.subviews) {
        if ([subview isKindOfClass:[UIImageView class]]) {
            icon = (UIImageView *)subview;
            break;
        }
    }
    icon.tintColor = dark ? [UIColor colorWithWhite:1.0 alpha:0.55] : UIColor.secondaryLabelColor;

    if (placeholder.length) {
        self.searchTextField.attributedPlaceholder =
            [[NSAttributedString alloc] initWithString:placeholder
                                            attributes:@{ NSForegroundColorAttributeName: placeholderColor }];
    }
}

- (void)hostAppearanceDidChange {
    [self applyHostAppearance];
}

@end
