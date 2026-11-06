

#import "DPOPluginDetailViewController.h"
#import "DPOHarvester.h"
#import "DPOViews.h"
#import "DPOTheme.h"
#import "DPORuntime.h"

@interface DPOPluginDetailViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) DPOPluginGroup *group;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@end

@implementation DPOPluginDetailViewController

- (instancetype)initWithGroup:(DPOPluginGroup *)group {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _group = group;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = self.group.name;
    self.view.backgroundColor = DPOColorBackground();

    _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
    _blurView.translatesAutoresizingMaskIntoConstraints = NO;
    _blurView.userInteractionEnabled = NO;
    [self.view addSubview:_blurView];

    UIView *tint = [[UIView alloc] init];
    tint.translatesAutoresizingMaskIntoConstraints = NO;
    tint.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.45];
    tint.userInteractionEnabled = NO;
    [self.view addSubview:tint];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 56;
    _tableView.contentInset = UIEdgeInsetsMake(6, 0, 28, 0);
    [_tableView registerClass:[DPOFeatureCell class] forCellReuseIdentifier:@"feature"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_blurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_blurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_blurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [tint.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tint.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [tint.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tint.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = NO;
}

#pragma mark - 数据

- (NSArray<DPOFeature *> *)features {
    return self.group.features ?: @[];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.features.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *version = self.group.version.length > 0
                            ? [NSString stringWithFormat:@" · v%@", self.group.version]
                            : @"";
    return [NSString stringWithFormat:@"%lu 个功能%@",
            (unsigned long)self.features.count, version];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 30)];
    container.backgroundColor = UIColor.clearColor;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 6, container.bounds.size.width - 40, 18)];
    label.font = DPOFont(11.5, UIFontWeightMedium);
    label.textColor = DPOColorTertiary();
    label.text = [self tableView:tableView titleForHeaderInSection:section];
    [container addSubview:label];
    return container;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 30.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DPOFeatureCell *cell = [tableView dequeueReusableCellWithIdentifier:@"feature" forIndexPath:indexPath];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= self.features.count) return cell;

    DPOFeature *feature = self.features[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    [cell configureWithFeature:feature showsPluginName:NO query:nil];
    cell.onSwitchChange = ^(BOOL isOn) {
        __strong typeof(weakSelf) self = weakSelf;
        [DPOHarvester setFeature:feature enabled:isOn];
        [self.tableView reloadRowsAtIndexPaths:@[ indexPath ]
                              withRowAnimation:UITableViewRowAnimationNone];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= self.features.count) return;

    DPOFeature *feature = self.features[(NSUInteger)indexPath.row];
    DPOHapticImpact(UIImpactFeedbackStyleLight);
    [DPOHarvester activateFeature:feature from:self];
}

@end
