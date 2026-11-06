

#import "DPODiagnostics.h"
#import "DPOTheme.h"
#import "DPORuntime.h"
#import "DPOViews.h"
#import "DPOLogViewController.h"

#pragma mark - Entry

@implementation DPODiagnosticEntry
@end

#pragma mark - Store

@implementation DPODiagnostics {
    NSMutableArray<DPODiagnosticEntry *> *_entries;
}

+ (instancetype)shared {
    static DPODiagnostics *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DPODiagnostics alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [NSMutableArray array];
    }
    return self;
}

- (NSArray<DPODiagnosticEntry *> *)entries {
    @synchronized (self) {
        return [_entries copy];
    }
}

- (NSUInteger)collectedCount {
    @synchronized (self) {
        NSUInteger count = 0;
        for (DPODiagnosticEntry *entry in _entries) {
            if ([entry.decision isEqualToString:@"已收纳"]) count += 1;
        }
        return count;
    }
}

- (void)reset {
    @synchronized (self) {
        [_entries removeAllObjects];
    }
}

- (void)addEntry:(DPODiagnosticEntry *)entry {
    if (entry == nil) return;
    @synchronized (self) {
        [_entries addObject:entry];
    }
}

- (NSString *)flushToDisk {
    NSMutableString *text = [NSMutableString string];
    NSArray<DPODiagnosticEntry *> *entries = self.entries;
    [text appendString:@"PluginNest 诊断\n"];
    [text appendFormat:@"设置项 %lu 个 / 已收纳 %lu 个\n", (unsigned long)entries.count, (unsigned long)self.collectedCount];
    if (self.context.length > 0) [text appendFormat:@"%@\n", self.context];
    [text appendString:@"\n"];

    for (DPODiagnosticEntry *entry in entries) {
        [text appendFormat:@"%@ | type=%@ | id=%@ | owner=%@ | block=%@ | class=%@ | %@\n",
                           entry.title, entry.itemClass, entry.identifier, entry.owner,
                           entry.blockImage, entry.classInfo, entry.decision];
    }

    NSString *path = @"/var/mobile/Library/Preferences/com.dpo.pluginnest.diag.txt";
    NSError *error = nil;
    BOOL written = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!written) {
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.dpo.pluginnest.diag.txt"];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return path;
}

@end

#pragma mark - Cell

@interface DPODiagnosticCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@end

@implementation DPODiagnosticCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = DPOFont(14, UIFontWeightMedium);
        _titleLabel.textColor = UIColor.labelColor;
        [self.contentView addSubview:_titleLabel];

        _badgeLabel = [[UILabel alloc] init];
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeLabel.font = DPOFont(9.5, UIFontWeightSemibold);
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.layer.cornerRadius = 5;
        _badgeLabel.clipsToBounds = YES;
        [self.contentView addSubview:_badgeLabel];

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = DPOFontMonospaced(9.5, UIFontWeightRegular);
        _detailLabel.textColor = DPOColorSecondary();
        _detailLabel.numberOfLines = 0;
        [self.contentView addSubview:_detailLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_badgeLabel.leadingAnchor constant:-8],

            [_badgeLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_badgeLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
            [_badgeLabel.widthAnchor constraintEqualToConstant:46],
            [_badgeLabel.heightAnchor constraintEqualToConstant:17],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_detailLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-9],
        ]];
    }
    return self;
}

- (void)configureWithEntry:(DPODiagnosticEntry *)entry {
    self.titleLabel.text = entry.title.length > 0 ? entry.title : @"(无标题)";

    BOOL collected = [entry.decision isEqualToString:@"已收纳"];
    if (collected) {
        self.badgeLabel.text = @"已收纳";
        self.badgeLabel.textColor = DPOColorAccent();
        self.badgeLabel.backgroundColor = DPOColorAccentSoft();
    } else {
        self.badgeLabel.text = entry.decision.length > 0 ? entry.decision : @"跳过";
        self.badgeLabel.textColor = DPOColorSecondary();
        self.badgeLabel.backgroundColor = [UIColor tertiarySystemFillColor];
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (entry.itemClass.length > 0) [lines addObject:[NSString stringWithFormat:@"type: %@", entry.itemClass]];
    if (entry.identifier.length > 0) [lines addObject:[NSString stringWithFormat:@"id: %@", entry.identifier]];
    if (entry.owner.length > 0) [lines addObject:[NSString stringWithFormat:@"归属: %@", entry.owner]];
    if (entry.blockImage.length > 0) [lines addObject:[NSString stringWithFormat:@"block: %@", entry.blockImage]];
    if (entry.classInfo.length > 0) [lines addObject:[NSString stringWithFormat:@"class: %@", entry.classInfo]];
    if (entry.section.length > 0) [lines addObject:[NSString stringWithFormat:@"section: %@", entry.section]];

    self.detailLabel.text = [lines componentsJoinedByString:@"\n"];
}

@end

#pragma mark - ViewController

@interface DPODiagnosticsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<DPODiagnosticEntry *> *entries;
@end

@implementation DPODiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"收纳诊断";
    self.view.backgroundColor = DPOColorBackground();

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(dpo_copy)];
    self.navigationItem.leftBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(dpo_close)],
        [[UIBarButtonItem alloc] initWithTitle:@"日志"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(dpo_showLog)],
    ];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 72;
    _tableView.backgroundColor = DPOColorBackground();
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    [_tableView registerClass:[DPODiagnosticCell class] forCellReuseIdentifier:@"cell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.entries = [DPODiagnostics shared].entries;
    self.tableView.tableHeaderView = [self dpo_makeHeader];
}

- (UIView *)dpo_makeHeader {
    NSUInteger total = self.entries.count;
    NSUInteger collected = [DPODiagnostics shared].collectedCount;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 82)];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, header.bounds.size.width - 32, 54)];
    label.numberOfLines = 0;
    label.font = DPOFont(12, UIFontWeightRegular);
    label.textColor = DPOColorSecondary();
    NSString *context = [DPODiagnostics shared].context;
    label.text = [NSString stringWithFormat:
                     @"共扫描到 %lu 个设置项，已收纳 %lu 个。\n%@\n没被收纳的项会显示它的归属镜像；如果归属为空，说明这个入口没有 block、也没有插件类名可查。",
                     (unsigned long)total, (unsigned long)collected, context.length > 0 ? context : @""];
    [header addSubview:label];
    return header;
}

- (void)dpo_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dpo_showLog {
    DPOLogViewController *controller = [[DPOLogViewController alloc] init];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)dpo_copy {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"PluginNest 诊断\n"];
    [text appendFormat:@"设置项 %lu 个 / 已收纳 %lu 个\n",
                       (unsigned long)self.entries.count,
                       (unsigned long)[DPODiagnostics shared].collectedCount];
    for (DPODiagnosticEntry *entry in self.entries) {
        [text appendFormat:@"- %@ | type=%@ | id=%@ | owner=%@ | block=%@ | class=%@ | %@\n",
                           entry.title, entry.itemClass, entry.identifier, entry.owner,
                           entry.blockImage, entry.classInfo, entry.decision];
    }
    [UIPasteboard generalPasteboard].string = text;
    [DPOToast show:@"诊断信息已复制"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DPODiagnosticCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    if (indexPath.row >= 0 && (NSUInteger)indexPath.row < self.entries.count) {
        [cell configureWithEntry:self.entries[(NSUInteger)indexPath.row]];
    }
    return cell;
}

@end
