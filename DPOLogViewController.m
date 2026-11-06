

#import "DPOLogViewController.h"
#import "DPOLogCenter.h"
#import "DPOTheme.h"
#import "DPORuntime.h"
#import "DPOViews.h"

@interface DPOLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *footerLabel;
@end

@implementation DPOLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"运行日志";
    self.view.backgroundColor = DPOColorBackground();

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(dpo_close)];
    UIBarButtonItem *exportItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(dpo_export)];
    UIBarButtonItem *copyItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(dpo_copy)];
    UIBarButtonItem *clearItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(dpo_confirmClear)];
    self.navigationItem.rightBarButtonItems = @[ exportItem, copyItem, clearItem ];

    _textView = [[UITextView alloc] init];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.alwaysBounceVertical = YES;
    _textView.backgroundColor = UIColor.clearColor;
    _textView.textColor = UIColor.labelColor;
    _textView.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    _textView.textContainerInset = UIEdgeInsetsMake(12, 12, 24, 12);
    _textView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_textView];

    _footerLabel = [[UILabel alloc] init];
    _footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _footerLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _footerLabel.textColor = DPOColorTertiary();
    _footerLabel.numberOfLines = 2;
    _footerLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_footerLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:_footerLabel.topAnchor constant:-4],

        [_footerLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_footerLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_footerLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-6],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dpo_reload)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self dpo_reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dpo_reload {
    DPOLogCenter *center = [DPOLogCenter shared];
    [center flush];

    NSString *text = [center text];
    if (text.length == 0) text = @"（暂无日志）";
    
    if (![self.textView.text isEqualToString:text]) {
        self.textView.text = text;
        if (text.length > 0) {
            NSRange end = NSMakeRange(text.length - 1, 1);
            [self.textView scrollRangeToVisible:end];
        }
    }

    self.footerLabel.text = [NSString stringWithFormat:@"v%@ · %lu 行 · %@",
                             DPOBuildVersion,
                             (unsigned long)[center lines].count,
                             [center filePath]];
}

- (void)dpo_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dpo_copy {
    NSString *text = [[DPOLogCenter shared] text];
    if (text.length == 0) return;
    [UIPasteboard generalPasteboard].string = text;
    [DPOToast show:@"日志已复制"];
}

- (void)dpo_confirmClear {
    if (self.presentedViewController != nil) return;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"清空运行日志"
                                            message:@"清空后无法恢复；已经导出的文件不受影响。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[DPOLogCenter shared] clear];
        [weakSelf dpo_reload];
        [DPOToast show:@"日志已清空"];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dpo_export {
    
    if (self.presentedViewController != nil) return;

    @try {
        DPOLogCenter *center = [DPOLogCenter shared];
        [center flush];

        NSString *text = [center text];
        if (text.length == 0) {
            [DPOToast show:@"还没有日志"];
            return;
        }

        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *name = [NSString stringWithFormat:@"PluginNest-%@.txt",
                          [formatter stringFromDate:[NSDate date]]];
        NSString *snapshot = [NSTemporaryDirectory() stringByAppendingPathComponent:name];

        NSError *error = nil;
        if (![text writeToFile:snapshot atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            DPOLogEvent(@"LOG", @"导出失败：%@", error.localizedDescription ?: @"未知错误");
            [DPOToast show:@"导出失败"];
            return;
        }

        
        
        
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ [NSURL fileURLWithPath:snapshot] ]
                                                                  asCopy:YES];
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:picker animated:YES completion:nil];
        DPOLogEvent(@"LOG", @"导出日志：%@", name);
    } @catch (NSException *exception) {
        DPOLogEvent(@"ERROR", @"导出日志异常：%@ %@", exception.name, exception.reason);
        [DPOToast show:@"导出失败，可以点左边的复制"];
    }
}

@end
