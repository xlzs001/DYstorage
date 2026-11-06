

#import "DPOOrganizerViewController.h"
#import "DPOHarvester.h"
#import "DPOViews.h"
#import "DPOTheme.h"
#import "DPORuntime.h"
#import "DPOPackageResolver.h"
#import "DPODiagnostics.h"
#import "DPOLogViewController.h"
#import "DPOLogCenter.h"

#pragma mark - 搜索结果分组

@interface DPOResultSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSMutableArray<DPOFeature *> *features;
@end

@implementation DPOResultSection
- (instancetype)init {
    self = [super init];
    if (self) {
        _features = [NSMutableArray array];
    }
    return self;
}
@end

@interface DPOOrganizerViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>

@property (nonatomic, weak) AWESettingBaseViewModel *viewModel;

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *searchContainer;
@property (nonatomic, strong) UIImageView *searchIcon;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) DPOEmptyView *emptyView;
@property (nonatomic, strong) UIView *listPanel;
@property (nonatomic, strong) UILabel *versionLabel;

@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSArray<DPOResultSection *> *resultSections;

@property (nonatomic, copy) NSArray<DPOPluginGroup *> *groups;
@property (nonatomic, copy) NSArray<DPOPluginGroup *> *visibleGroups;
@property (nonatomic, copy) NSString *lastSignature;
@property (nonatomic, assign) BOOL didAnimateIn;

- (void)dpo_storeDidUpdate:(NSNotification *)notification;

@end

@implementation DPOOrganizerViewController

- (instancetype)initWithViewModel:(AWESettingBaseViewModel *)viewModel {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _viewModel = viewModel;
        _groups = @[];
        _visibleGroups = @[];
    }
    return self;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = UIColor.clearColor;
    [self dpo_setupGlassBackground];
    [self dpo_setupHeader];
    [self dpo_setupSearch];
    [self dpo_setupTableAndFooter];
    [self dpo_setupEmptyView];

    [self dpo_reloadGroupsForce:YES];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(dpo_storeDidUpdate:)
                   name:DPOStoreDidUpdateNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(dpo_storeDidUpdate:)
                   name:DPOPluginInfoDidUpdateNotification
                 object:nil];

    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[DPOPackageResolver shared] prewarm];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dpo_storeDidUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self dpo_reloadGroupsForce:YES];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = YES;

    
    
    UIGestureRecognizer *popGesture = self.navigationController.interactivePopGestureRecognizer;
    popGesture.enabled = YES;

    
    [self dpo_reloadGroupsForce:NO];
}

- (BOOL)accessibilityPerformEscape {
    [self dpo_close];
    return YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBarHidden = NO;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

#pragma mark - 外观

- (UIButton *)dpo_makeCircleButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config]
            forState:UIControlStateNormal];
    button.tintColor = [UIColor.labelColor colorWithAlphaComponent:0.62];
    button.backgroundColor = UIColor.secondarySystemFillColor;   
    button.layer.cornerRadius = 12.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:24].active = YES;
    [button.heightAnchor constraintEqualToConstant:24].active = YES;
    return button;
}

- (void)dpo_setupHeader {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = @"DYstorage";
    _titleLabel.font = [UIFont systemFontOfSize:19.5 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.labelColor;
    [self.view addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = DPOFont(10.5, UIFontWeightRegular);
    _subtitleLabel.textColor = DPOColorSecondary();
    [self.view addSubview:_subtitleLabel];

    // 刷新按钮已移除：需要重扫时在标题上连点五次进日志页，那里有「重扫」的入口在诊断里。
    
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:2],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];

    // 隐藏入口：标题连点五次 → 运行日志（导出 / 清空 / 关闭都在里面）。
    UITapGestureRecognizer *logTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dpo_titleTapped)];
    _titleLabel.userInteractionEnabled = YES;
    [_titleLabel addGestureRecognizer:logTap];
}

- (void)dpo_setupSearch {
    _searchContainer = [[UIView alloc] init];
    _searchContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _searchContainer.backgroundColor = UIColor.whiteColor;
    _searchContainer.layer.cornerRadius = 12.0;
    _searchContainer.layer.cornerCurve = kCACornerCurveContinuous;
    _searchContainer.layer.borderWidth = 0.5;
    _searchContainer.layer.borderColor = [UIColor.blackColor colorWithAlphaComponent:0.05].CGColor;
    _searchContainer.layer.shadowOpacity = 0.0;
    _searchContainer.isAccessibilityElement = NO;
    [self.view addSubview:_searchContainer];

    UIImageSymbolConfiguration *iconConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightRegular];
    _searchIcon = [[UIImageView alloc] initWithImage:
                       [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:iconConfig]];
    _searchIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _searchIcon.tintColor = DPOColorTertiary();
    _searchIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_searchContainer addSubview:_searchIcon];

    _searchField = [[UITextField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.font = DPOFont(16.0, UIFontWeightRegular);
    _searchField.textColor = UIColor.labelColor;
    _searchField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:@"搜索插件与功能"
                                        attributes:@{ NSForegroundColorAttributeName: DPOColorTertiary() }];
    _searchField.textAlignment = NSTextAlignmentLeft;
    // 搜索功能封存：整条胶囊只做视觉，点一下弹「下次一定」。
    _searchField.userInteractionEnabled = NO;
    _searchField.clearButtonMode = UITextFieldViewModeNever;

    UITapGestureRecognizer *searchTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dpo_showSearchNotice)];
    [_searchContainer addGestureRecognizer:searchTap];
    [_searchContainer addSubview:_searchField];

    
    NSLayoutConstraint *searchWidth =
        [_searchContainer.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-32];
    searchWidth.priority = 999;

    [NSLayoutConstraint activateConstraints:@[
        [_searchContainer.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:10],
        [_searchContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_searchContainer.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_searchContainer.widthAnchor constraintLessThanOrEqualToConstant:460],
        searchWidth,
        [_searchContainer.heightAnchor constraintEqualToConstant:44],

        [_searchIcon.leadingAnchor constraintEqualToAnchor:_searchContainer.leadingAnchor constant:14],
        [_searchIcon.centerYAnchor constraintEqualToAnchor:_searchContainer.centerYAnchor],
        [_searchIcon.widthAnchor constraintEqualToConstant:18],
        [_searchIcon.heightAnchor constraintEqualToConstant:18],

        
        [_searchField.leadingAnchor constraintEqualToAnchor:_searchIcon.trailingAnchor constant:8],
        [_searchField.trailingAnchor constraintEqualToAnchor:_searchContainer.trailingAnchor constant:-12],
        [_searchField.topAnchor constraintEqualToAnchor:_searchContainer.topAnchor],
        [_searchField.bottomAnchor constraintEqualToAnchor:_searchContainer.bottomAnchor],
    ]];
}

- (void)dpo_setupGlassBackground {
    // iOS 设置页那套：浅灰底 + 一整块白卡，靠明暗对比分层，不靠毛玻璃。
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
}

- (void)dpo_setupTableAndFooter {
    // 一整块白卡，里面塞所有行 + 细分隔线
    _listPanel = [[UIView alloc] init];
    _listPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _listPanel.backgroundColor = UIColor.whiteColor;
    _listPanel.layer.cornerRadius = 18.0;
    _listPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _listPanel.clipsToBounds = YES;
    [self.view addSubview:_listPanel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    _tableView.separatorColor = [[UIColor separatorColor] colorWithAlphaComponent:0.32];
    // 左右都缩进：线不顶到卡片右边，看起来才像"内容之间的分隔"而不是"切一刀"
    _tableView.separatorInset = UIEdgeInsetsMake(0, 46, 0, 16);
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 60;
    _tableView.showsVerticalScrollIndicator = NO;
    _tableView.sectionHeaderHeight = 0.01;
    if (@available(iOS 15.0, *)) {
        // iOS 15+ 默认给每个 section 头顶加 ~22pt 留白，正是"上下间距太大"的元凶
        _tableView.sectionHeaderTopPadding = 0;
    }
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 4, 0);
    if (@available(iOS 11.0, *)) {
        _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [_tableView registerClass:[DPOPluginGroupCell class] forCellReuseIdentifier:@"group"];
    [_tableView registerClass:[DPOFeatureCell class] forCellReuseIdentifier:@"feature"];
    [_tableView registerClass:[DPOResultCell class] forCellReuseIdentifier:@"result"];
    [_listPanel addSubview:_tableView];

    _versionLabel = [[UILabel alloc] init];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.textAlignment = NSTextAlignmentCenter;
    _versionLabel.font = DPOFontMonospaced(10.5, UIFontWeightRegular);
    _versionLabel.textColor = DPOColorTertiary();
    _versionLabel.text = [NSString stringWithFormat:@"v%@", DPOBuildVersion];
    [self.view addSubview:_versionLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_listPanel.topAnchor constraintEqualToAnchor:_searchContainer.bottomAnchor constant:12],
        [_listPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_listPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_listPanel.bottomAnchor constraintEqualToAnchor:_versionLabel.topAnchor constant:-10],

        [_tableView.topAnchor constraintEqualToAnchor:_listPanel.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:_listPanel.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:_listPanel.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:_listPanel.bottomAnchor],

        [_versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_versionLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
    ]];
}

- (UIButton *)dpo_makeFooterButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = DPOFont(10.0, UIFontWeightRegular);
    [button setTitleColor:DPOColorTertiary() forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)dpo_setupEmptyView {
    _emptyView = [[DPOEmptyView alloc] init];
    _emptyView.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyView.hidden = YES;
    [self.view addSubview:_emptyView];

    [NSLayoutConstraint activateConstraints:@[
        [_emptyView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_emptyView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-16],
        [_emptyView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [_emptyView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

#pragma mark - 数据

- (NSString *)dpo_signatureForGroups:(NSArray<DPOPluginGroup *> *)groups {
    NSMutableString *signature = [NSMutableString string];
    for (DPOPluginGroup *group in groups) {
        [signature appendFormat:@"%@|%@|%lu|", group.name ?: @"", group.version ?: @"",
                              (unsigned long)group.deepFeatureCount];
        for (DPOFeature *feature in group.features) {
            [signature appendFormat:@"%@,%@;", feature.key ?: @"", feature.isSwitch ? (feature.isOn ? @"1" : @"0") : @"-"];
        }
    }
    return signature;
}

- (void)dpo_reloadGroupsForce:(BOOL)force {
    NSArray<DPOPluginGroup *> *groups = [DPOFeatureStore shared].groups ?: @[];
    NSString *signature = [self dpo_signatureForGroups:groups];

    if (!force && self.lastSignature != nil && [signature isEqualToString:self.lastSignature]) {
        return;   
    }

    self.lastSignature = signature;
    self.groups = groups;
    self.visibleGroups = [self dpo_deduplicatedGroups:groups];
    if ([self dpo_isSearching]) [self dpo_rebuildSearchResults];
    [self.tableView reloadData];
    [self dpo_updateEmptyState];
    [self dpo_updateSummary];
}

- (void)dpo_updateSummary {
    DPOFeatureStore *store = [DPOFeatureStore shared];
    
    if (store.pluginCount == 0) {
        self.subtitleLabel.text = [NSString stringWithFormat:@"v%@", DPOBuildVersion];
    } else {
        self.subtitleLabel.text = [NSString stringWithFormat:@"已收纳 %lu 个插件",
                                   (unsigned long)store.pluginCount];
    }
}

- (NSArray<DPOPluginGroup *> *)dpo_deduplicatedGroups:(NSArray<DPOPluginGroup *> *)groups {
    if (groups.count < 2) return groups;

    NSMutableArray<DPOPluginGroup *> *result = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *indexByKey = [NSMutableDictionary dictionary];

    for (DPOPluginGroup *group in groups) {
        // 按「插件身份」（可执行文件）去重，而不是按显示名：两个插件可能重名，
        // 旧实现按名字去重会把另一个插件的功能整组丢掉。
        NSString *key = DPOPluginIdentity(group.imagePath);
        if (key.length == 0) {
            key = [[group.name stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        }
        if (key.length == 0) {
            [result addObject:group];
            continue;
        }
        NSNumber *existing = indexByKey[key];
        if (existing == nil) {
            indexByKey[key] = @(result.count);
            [result addObject:group];
            continue;
        }

        // 同一个插件的两个路径：合并功能，而不是留一个丢一个。
        DPOPluginGroup *kept = result[existing.unsignedIntegerValue];
        NSMutableArray<DPOFeature *> *features = [kept.features mutableCopy] ?: [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (DPOFeature *feature in features) {
            if (feature.key.length > 0) [seen addObject:feature.key];
        }
        for (DPOFeature *feature in group.features) {
            if (feature.key.length > 0 && [seen containsObject:feature.key]) continue;
            if (feature.key.length > 0) [seen addObject:feature.key];
            [features addObject:feature];
        }

        DPOPluginGroup *merged = [[DPOPluginGroup alloc] init];
        merged.imagePath = kept.imagePath;
        merged.name = kept.name.length > 0 ? kept.name : group.name;
        merged.version = kept.version.length > 0 ? kept.version : group.version;
        merged.packageID = kept.packageID.length > 0 ? kept.packageID : group.packageID;
        merged.iconName = kept.iconName.length > 0 ? kept.iconName : group.iconName;
        merged.deepFeatureCount = MAX(kept.deepFeatureCount, group.deepFeatureCount);
        merged.features = features;
        result[existing.unsignedIntegerValue] = merged;
    }
    return result;
}

#pragma mark - 交互

- (void)dpo_close {
    if (self.navigationController.presentingViewController != nil &&
        self.navigationController.viewControllers.firstObject == self) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (self.navigationController != nil) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dpo_showSearchNotice {
    DPOHapticImpact(UIImpactFeedbackStyleLight);
    [DPOGlassPopup showTitle:@"下次一定"
                     message:@"搜索功能先封存了，先在下面的插件列表里翻一翻吧。"];
}

- (void)dpo_titleTapped {
    // 连点五次进日志：刷新/导出/清空都在那一页，主界面不再放按钮。
    static NSInteger taps = 0;
    static NSTimeInterval lastTap = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - lastTap > 3.0) taps = 0;
    lastTap = now;
    taps += 1;
    DPOLogEvent(@"TAP", @"标题点击 %ld/5", (long)taps);
    if (taps < 5) return;

    taps = 0;
    DPOHapticImpact(UIImpactFeedbackStyleMedium);
    [self dpo_showLog];
}

- (void)dpo_showDiagnostics {
    DPODiagnosticsViewController *controller = [[DPODiagnosticsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)dpo_showLog {
    DPOLogViewController *controller = [[DPOLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 搜索（就地过滤，不跳页）

- (BOOL)dpo_isSearching {
    return self.query.length > 0;
}

- (void)dpo_searchChanged:(UITextField *)field {
    self.query = [field.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    [self dpo_rebuildSearchResults];
    [self.tableView reloadData];
    [self dpo_updateEmptyState];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)dpo_rebuildSearchResults {
    if (![self dpo_isSearching]) {
        self.resultSections = @[];
        return;
    }

    // 插件名也参与搜索：有些插件的入口行标题跟卡片名不是一回事（甚至没有入口行），
    // 只搜功能标题就会漏。这里给每个命中的插件补一条「打开插件」的结果行。
    NSString *lowerQuery = [self.query lowercaseString];
    NSMutableArray<DPOFeature *> *corpus =
        [NSMutableArray arrayWithArray:[[DPOFeatureStore shared] allSearchableFeatures]];
    NSUInteger groupRows = 0;

    for (DPOPluginGroup *group in self.visibleGroups) {
        if (group.name.length == 0) continue;
        if (![[group.name lowercaseString] containsString:lowerQuery]) continue;

        DPOFeature *row = [[DPOFeature alloc] init];
        row.title = group.name;
        row.pluginName = group.name;
        row.pluginImage = group.imagePath;
        row.pluginVersion = group.version;
        row.isDeep = YES;                       // 只是借用「在插件设置页中打开」的副标题
        row.key = [NSString stringWithFormat:@"group|%@", group.imagePath ?: group.name];
        [row refreshSearchBlob];
        [corpus addObject:row];
        groupRows += 1;
    }

    NSArray<DPOFeature *> *raw = DPOSearchFeatures(corpus, self.query);

    // 只认「标题命中」：DPOSearchFeatures 还会按副标题/分组名/插件名打分，
    // 结果就是搜「移除」会带出一堆标题里根本没这两个字的行。这里再收一次。
    NSMutableArray<DPOFeature *> *hits = [NSMutableArray array];
    NSString *needle = [self.query lowercaseString];
    for (DPOFeature *feature in raw) {
        NSString *title = [feature.title lowercaseString] ?: @"";
        if (title.length == 0) continue;
        if ([title containsString:needle]) {
            [hits addObject:feature];
            continue;
        }
        // 英文/拼音首字母：输入 ys 也能命中「隐私」
        NSString *initials = [[DPOPinyinInitials(feature.title) lowercaseString] copy];
        if (initials.length > 0 && [initials hasPrefix:needle]) {
            [hits addObject:feature];
        }
    }
    NSMutableArray<DPOResultSection *> *sections = [NSMutableArray array];
    NSMutableDictionary<NSString *, DPOResultSection *> *byPlugin = [NSMutableDictionary dictionary];

    for (DPOFeature *feature in hits) {
        NSString *pluginKey = feature.pluginImage.length > 0 ? feature.pluginImage : (feature.pluginName ?: @"");
        NSString *sectionPart = feature.sectionTitle ?: @"";
        NSString *key = [NSString stringWithFormat:@"%@|%@", pluginKey, sectionPart];
        DPOResultSection *section = byPlugin[key];
        if (section == nil) {
            section = [[DPOResultSection alloc] init];
            NSString *pluginName = [self dpo_displayNameForFeature:feature];
            section.title = sectionPart.length > 0
                                ? [NSString stringWithFormat:@"%@ - %@", pluginName, sectionPart]
                                : pluginName;
            byPlugin[key] = section;
            [sections addObject:section];
        }
        [section.features addObject:feature];
    }
    self.resultSections = sections;
    DPOFeatureStore *store = [DPOFeatureStore shared];
    DPOLogEvent(@"SEARCH", @"kw=%@ 命中=%lu(初筛%lu) 分组=%lu 插件行=%lu | 语料 活=%lu 深=%lu 静=%lu",
                self.query, (unsigned long)hits.count, (unsigned long)raw.count,
                (unsigned long)sections.count,
                (unsigned long)groupRows,
                (unsigned long)store.featureCount, (unsigned long)store.deepCount,
                (unsigned long)store.staticCount);
}

- (NSString *)dpo_locationTextForFeature:(DPOFeature *)feature {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    NSString *pluginName = [self dpo_displayNameForFeature:feature];
    if (pluginName.length > 0) [parts addObject:pluginName];

    // locatorTrail 的最后一段是这一行自己，前面几段才是「二级 / 三级页面」
    NSArray<NSString *> *trail = feature.locatorTrail;
    for (NSUInteger index = 0; index + 1 < trail.count; index++) {
        NSString *step = trail[index];
        if (![step isKindOfClass:[NSString class]] || step.length == 0) continue;
        if (parts.lastObject != nil && [parts.lastObject isEqualToString:step]) continue;
        [parts addObject:step];
        if (parts.count >= 3) break;
    }

    if (parts.count == 1 && feature.sectionTitle.length > 0) {
        [parts addObject:feature.sectionTitle];
    }
    if (parts.count == 1) [parts addObject:@"插件设置"];

    return [parts componentsJoinedByString:@" › "];
}

- (NSString *)dpo_displayNameForFeature:(DPOFeature *)feature {
    if (feature.pluginName.length > 0) return feature.pluginName;
    NSString *name = feature.pluginImage.lastPathComponent.stringByDeletingPathExtension;
    return name.length > 0 ? name : @"其他插件";
}

- (void)dpo_updateEmptyState {
    self.tableView.backgroundColor = [self dpo_isSearching] ? UIColor.systemGroupedBackgroundColor
                                                            : UIColor.clearColor;
    if ([self dpo_isSearching]) {
        BOOL hasHits = self.resultSections.count > 0;
        self.emptyView.hidden = hasHits;
        self.tableView.hidden = !hasHits;
        if (hasHits) return;

        [self.emptyView configureWithSymbol:@"questionmark.circle"
                                      title:[NSString stringWithFormat:@"没有找到「%@」", self.query]
                                   subtitle:@"换个更短的关键词；插件内部功能需要先打开过对应插件页。"];
        [self.emptyView setActionTitle:nil];
        self.emptyView.onAction = nil;
        return;
    }

    self.tableView.hidden = NO;
    BOOL empty = (self.visibleGroups.count == 0);
    self.emptyView.hidden = !empty;
    if (!empty) return;

    [self.emptyView configureWithSymbol:@"shippingbox"
                                  title:@"还没有收纳到插件"
                               subtitle:@"安装第三方插件后，重新打开抖音设置页即可自动出现"];
    __weak typeof(self) weakSelf = self;
    [self.emptyView setActionTitle:@"查看诊断"];
    self.emptyView.onAction = ^{
        [weakSelf dpo_showDiagnostics];
    };
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if ([self dpo_isSearching]) return (NSInteger)self.resultSections.count;
    return self.visibleGroups.count > 0 ? 1 : 0;   // 一个面板 = 一个 section
}

- (DPOPluginGroup *)dpo_groupAtRow:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.visibleGroups.count) return nil;
    return self.visibleGroups[(NSUInteger)row];
}

- (DPOPluginGroup *)dpo_groupInSection:(NSInteger)section {
    if (section < 0 || (NSUInteger)section >= self.visibleGroups.count) return nil;
    return self.visibleGroups[(NSUInteger)section];
}

- (DPOFeature *)dpo_featureAtIndexPath:(NSIndexPath *)indexPath {
    if (![self dpo_isSearching]) return nil;
    if (indexPath.section < 0 || (NSUInteger)indexPath.section >= self.resultSections.count) return nil;
    NSArray<DPOFeature *> *features = self.resultSections[(NSUInteger)indexPath.section].features;
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= features.count) return nil;
    return features[(NSUInteger)indexPath.row];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self dpo_isSearching]) {
        if (section < 0 || (NSUInteger)section >= self.resultSections.count) return 0;
        return (NSInteger)self.resultSections[(NSUInteger)section].features.count;
    }
    return self.visibleGroups.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self dpo_isSearching] ? 54.0 : 60.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return [self dpo_isSearching] ? 10.0 : 0.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = UIColor.clearColor;
    return view;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self dpo_isSearching] ? 26.0 : 0.01;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (![self dpo_isSearching]) return nil;
    if (section < 0 || (NSUInteger)section >= self.resultSections.count) return nil;
    return self.resultSections[(NSUInteger)section].title;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view
       forSection:(NSInteger)section {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.font = DPOFont(11.0, UIFontWeightMedium);
    header.textLabel.textColor = DPOColorTertiary();
    header.contentView.backgroundColor = UIColor.whiteColor;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self dpo_isSearching]) {
        DPOResultCell *cell = [tableView dequeueReusableCellWithIdentifier:@"result"
                                                              forIndexPath:indexPath];
        DPOFeature *feature = [self dpo_featureAtIndexPath:indexPath];
        if (feature == nil) return cell;

        NSInteger rows = [tableView numberOfRowsInSection:indexPath.section];
        [cell configureTitle:feature.title
                    location:[self dpo_locationTextForFeature:feature]
                  pluginName:[self dpo_displayNameForFeature:feature]
                       query:self.query
                  firstInSet:(indexPath.row == 0)
                   lastInSet:(indexPath.row == rows - 1)];
        return cell;
    }

    DPOPluginGroup *group = [self dpo_groupAtRow:indexPath.row];
    if (group == nil) {
        return [tableView dequeueReusableCellWithIdentifier:@"group" forIndexPath:indexPath];
    }

    DPOPluginGroupCell *cell = [tableView dequeueReusableCellWithIdentifier:@"group" forIndexPath:indexPath];
    __weak typeof(self) weakSelf = self;
    [cell configureWithGroup:group expanded:NO];
    cell.onOpen = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self dpo_openPluginGroup:group];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if ([self dpo_isSearching]) {
        DPOFeature *feature = [self dpo_featureAtIndexPath:indexPath];
        if (feature == nil) return;
        DPOHapticImpact(UIImpactFeedbackStyleLight);
        [self.searchField resignFirstResponder];

        // 「插件名」这条结果：直接打开该插件的设置页，不走定位。
        if ([feature.key hasPrefix:@"group|"]) {
            for (DPOPluginGroup *group in self.visibleGroups) {
                if (![group.imagePath isEqualToString:feature.pluginImage]) continue;
                [self dpo_openPluginGroup:group];
                return;
            }
        }

        [DPOHarvester locateFeature:feature from:self];
        return;
    }

    DPOPluginGroup *group = [self dpo_groupAtRow:indexPath.row];
    if (group == nil) return;

    DPOHapticImpact(UIImpactFeedbackStyleLight);
    [self dpo_openPluginGroup:group];
}

- (void)dpo_openPluginGroup:(DPOPluginGroup *)group {
    if (group == nil) return;

    DPOFeature *target = nil;
    for (DPOFeature *feature in group.features) {
        if (feature.isSwitch || feature.item == nil) continue;
        if (feature.item.cellTappedBlock == nil) continue;
        target = feature;
        break;
    }
    DPOHapticImpact(UIImpactFeedbackStyleLight);

    if (target != nil) {
        [DPOHarvester activateFeature:target from:self];
        return;
    }
    if ([DPOHarvester openPluginSettingsPageForImage:group.imagePath from:self]) return;

    [DPOToast show:[NSString stringWithFormat:@"%@ 没有可打开的设置页", group.name]];
}

#pragma mark - 动画

- (void)dpo_animateVisibleCells {
    NSArray<UITableViewCell *> *cells = self.tableView.visibleCells;
    for (NSUInteger index = 0; index < cells.count; index++) {
        UITableViewCell *cell = cells[index];
        cell.alpha = 0.0;
        cell.transform = CGAffineTransformMakeTranslation(0, 10);
        [UIView animateWithDuration:0.36
                              delay:0.02 * index
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            cell.alpha = 1.0;
            cell.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

@end
