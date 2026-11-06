

#import "DPOViews.h"
#import "DPOTheme.h"
#import "DPORuntime.h"

#pragma mark - DPOFeatureCell

@interface DPOFeatureCell ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) UISwitch *switchView;
@property (nonatomic, strong) UIImageView *chevronView;
@property (nonatomic, strong) NSLayoutConstraint *trailingToChevron;
@property (nonatomic, strong) NSLayoutConstraint *trailingToSwitch;
@end

@implementation DPOFeatureCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.58];
        self.contentView.backgroundColor = UIColor.clearColor;
        [self dpo_setup];
    }
    return self;
}

- (void)dpo_setup {
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.numberOfLines = 0;
    _titleLabel.font = DPOFont(16, UIFontWeightRegular);
    _titleLabel.textColor = UIColor.labelColor;

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.font = DPOFont(12, UIFontWeightRegular);
    _subtitleLabel.textColor = DPOColorSecondary();

    _stackView = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _subtitleLabel ]];
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.alignment = UIStackViewAlignmentFill;
    _stackView.spacing = 2.0;
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_stackView];

    _chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chevronView.tintColor = DPOColorTertiary();
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    [_chevronView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_chevronView];

    _switchView = [[UISwitch alloc] init];
    _switchView.onTintColor = DPOColorAccent();
    _switchView.translatesAutoresizingMaskIntoConstraints = NO;
    [_switchView addTarget:self action:@selector(dpo_switchChanged)
          forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_switchView];

    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    _trailingToChevron = [_stackView.trailingAnchor constraintLessThanOrEqualToAnchor:_chevronView.leadingAnchor
                                                                            constant:-10];
    _trailingToSwitch = [_stackView.trailingAnchor constraintLessThanOrEqualToAnchor:_switchView.leadingAnchor
                                                                           constant:-10];
    _trailingToChevron.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [_stackView.topAnchor constraintEqualToAnchor:margins.topAnchor constant:1],
        [_stackView.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-1],
        [_stackView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],

        [_chevronView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_chevronView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:9],
        [_chevronView.heightAnchor constraintEqualToConstant:15],

        [_switchView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_switchView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];

    
    self.contentView.layoutMargins = UIEdgeInsetsMake(11, 0, 11, 0);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.contentView.transform = CGAffineTransformIdentity;
    self.onSwitchChange = nil;
    self.subtitleLabel.hidden = YES;
    self.accessoryType = UITableViewCellAccessoryNone;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (!self.cardStyle) {
        self.contentView.layer.cornerRadius = 0;
        self.contentView.layer.borderWidth = 0;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.contentView.clipsToBounds = NO;
        return;
    }

    
    self.contentView.frame = UIEdgeInsetsInsetRect(self.bounds, UIEdgeInsetsMake(3.0, 16.0, 3.0, 16.0));
    self.contentView.layer.cornerRadius = 18.0;
    self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    self.contentView.layer.borderWidth = 0.5;
    self.contentView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.contentView.clipsToBounds = YES;
}

- (void)configureWithFeature:(DPOFeature *)feature
             showsPluginName:(BOOL)showsPluginName
                       query:(NSString *)query {
    if (feature == nil) return;

    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:feature.title ?: @""];
    [title addAttributes:@{
        NSFontAttributeName: DPOFont(16, UIFontWeightRegular),
        NSForegroundColorAttributeName: UIColor.labelColor,
    } range:NSMakeRange(0, title.length)];

    NSRange match = DPOMatchRangeInString(feature.title, query);
    if (match.location != NSNotFound) {
        [title addAttributes:@{
            NSFontAttributeName: DPOFont(16, UIFontWeightSemibold),
            NSForegroundColorAttributeName: DPOColorAccent(),
        } range:match];
    }
    self.titleLabel.attributedText = title;

    NSString *subtitle = feature.subtitle;
    NSString *pluginDesc = feature.pluginName;
    if (feature.pluginVersion.length > 0 && feature.pluginName.length > 0) {
        pluginDesc = [NSString stringWithFormat:@"%@ v%@", feature.pluginName, feature.pluginVersion];
    }

    if (feature.isDeep || feature.item == nil) {
        subtitle = (showsPluginName && pluginDesc.length > 0)
                       ? [NSString stringWithFormat:@"%@ · 在插件设置页中打开", pluginDesc]
                       : @"在插件设置页中打开";
    } else if (showsPluginName && feature.pluginName.length > 0) {
        subtitle = subtitle.length > 0
                       ? [NSString stringWithFormat:@"%@ · %@", pluginDesc, subtitle]
                       : pluginDesc;
    }
    self.subtitleLabel.text = subtitle;
    self.subtitleLabel.hidden = (subtitle.length == 0);

    BOOL showsSwitch = feature.isSwitch && !feature.isDeep && feature.item != nil;
    self.switchView.hidden = !showsSwitch;
    self.chevronView.hidden = showsSwitch;
    self.selectionStyle = showsSwitch ? UITableViewCellSelectionStyleNone
                                      : UITableViewCellSelectionStyleDefault;

    self.trailingToChevron.active = !showsSwitch;
    self.trailingToSwitch.active = showsSwitch;

    if (showsSwitch) {
        self.switchView.on = feature.isOn;
    }
}

- (void)dpo_switchChanged {
    if (self.onSwitchChange) self.onSwitchChange(self.switchView.isOn);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    if (self.switchView.hidden == NO) return;   

    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.contentView.transform = highlighted ? CGAffineTransformMakeScale(0.982, 0.982)
                                                 : CGAffineTransformIdentity;
    } completion:nil];
}

@end

#pragma mark - DPOPluginHeaderView

@interface DPOPluginHeaderView ()
@property (nonatomic, strong) UIView *avatarView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UILabel *initialLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIView *versionPill;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *countLabel;
@end

@implementation DPOPluginHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = DPOColorBackground();
        [self dpo_setup];
    }
    return self;
}

- (void)dpo_setup {
    _avatarView = [[UIView alloc] init];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.layer.cornerRadius = 11.0;
    _avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarView.clipsToBounds = YES;
    [self addSubview:_avatarView];

    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0, 0);
    _gradientLayer.endPoint = CGPointMake(1, 1);
    [_avatarView.layer addSublayer:_gradientLayer];

    _initialLabel = [[UILabel alloc] init];
    _initialLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _initialLabel.font = DPOFont(17, UIFontWeightSemibold);
    _initialLabel.textColor = UIColor.whiteColor;
    _initialLabel.textAlignment = NSTextAlignmentCenter;
    [_avatarView addSubview:_initialLabel];

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = DPOFont(15, UIFontWeightSemibold);
    _nameLabel.textColor = UIColor.labelColor;
    [self addSubview:_nameLabel];

    _versionPill = [[UIView alloc] init];
    _versionPill.translatesAutoresizingMaskIntoConstraints = NO;
    _versionPill.layer.cornerRadius = 7.0;
    _versionPill.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_versionPill];

    _versionLabel = [[UILabel alloc] init];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = DPOFontMonospaced(10.5, UIFontWeightMedium);
    [_versionPill addSubview:_versionLabel];

    _countLabel = [[UILabel alloc] init];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = DPOFont(12, UIFontWeightRegular);
    _countLabel.textColor = DPOColorTertiary();
    _countLabel.textAlignment = NSTextAlignmentRight;
    [self addSubview:_countLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
        [_avatarView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:36],
        [_avatarView.heightAnchor constraintEqualToConstant:36],

        [_initialLabel.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_initialLabel.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:11],
        [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:9],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_countLabel.leadingAnchor constant:-8],

        [_versionPill.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_versionPill.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
        [_versionPill.heightAnchor constraintEqualToConstant:17],
        [_versionPill.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-6],

        [_versionLabel.leadingAnchor constraintEqualToAnchor:_versionPill.leadingAnchor constant:6],
        [_versionLabel.trailingAnchor constraintEqualToAnchor:_versionPill.trailingAnchor constant:-6],
        [_versionLabel.centerYAnchor constraintEqualToAnchor:_versionPill.centerYAnchor],

        [_countLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
        [_countLabel.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
    ]];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradientLayer.frame = _avatarView.bounds;
}

- (void)configureWithGroup:(DPOPluginGroup *)group {
    if (group == nil) return;

    NSString *name = group.name.length > 0 ? group.name : @"未知插件";
    _nameLabel.text = name;

    NSString *initial = @"?";
    if (name.length > 0) {
        // 用 composed character sequence 取首字，避免 emoji / 组合字符被截成半个代理对。
        NSRange firstRange = [name rangeOfComposedCharacterSequenceAtIndex:0];
        initial = [[name substringWithRange:firstRange] uppercaseString];
    }
    _initialLabel.text = initial;

    NSArray<UIColor *> *colors = DPOAvatarColors((NSInteger)(labs((long)[group.imagePath hash]) % 6));
    _gradientLayer.colors = @[ (id)(colors.firstObject ?: DPOColorAccent()).CGColor,
                               (id)(colors.lastObject ?: DPOColorAccent()).CGColor ];

    BOOL hasVersion = group.version.length > 0;
    _versionLabel.text = hasVersion ? [NSString stringWithFormat:@"v%@", group.version] : @"版本未知";
    _versionLabel.textColor = hasVersion ? DPOColorAccent() : DPOColorTertiary();
    _versionPill.backgroundColor = hasVersion ? DPOColorAccentSoft()
                                              : [UIColor tertiarySystemFillColor];

    _countLabel.text = [NSString stringWithFormat:@"%lu 项", (unsigned long)group.features.count];
}

@end

#pragma mark - DPOEmptyView

@interface DPOEmptyView ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *actionButton;
@end

@implementation DPOEmptyView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] init];
        _iconView.tintColor = DPOColorTertiary();
        _iconView.contentMode = UIViewContentModeScaleAspectFit;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = DPOFont(13.0, UIFontWeightMedium);
        _titleLabel.textColor = DPOColorSecondary();
        _titleLabel.textAlignment = NSTextAlignmentCenter;

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.font = DPOFont(11.0, UIFontWeightRegular);
        _subtitleLabel.textColor = DPOColorTertiary();
        _subtitleLabel.textAlignment = NSTextAlignmentCenter;
        _subtitleLabel.numberOfLines = 0;

        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _actionButton.hidden = YES;
        _actionButton.titleLabel.font = DPOFont(11.0, UIFontWeightMedium);
        [_actionButton setTitleColor:DPOColorAccent() forState:UIControlStateNormal];
        _actionButton.backgroundColor = DPOColorAccentSoft();
        _actionButton.layer.cornerRadius = 12.0;
        _actionButton.layer.cornerCurve = kCACornerCurveContinuous;
        [_actionButton addTarget:self action:@selector(dpo_actionTapped)
                forControlEvents:UIControlEventTouchUpInside];
        [_actionButton.widthAnchor constraintGreaterThanOrEqualToConstant:84].active = YES;
        [_actionButton.heightAnchor constraintEqualToConstant:24].active = YES;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                                  @[ _iconView, _titleLabel, _subtitleLabel, _actionButton ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 10;
        [stack setCustomSpacing:14 afterView:_subtitleLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:32],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-32],
            [_iconView.widthAnchor constraintEqualToConstant:32],
            [_iconView.heightAnchor constraintEqualToConstant:32],
        ]];
    }
    return self;
}

- (void)configureWithSymbol:(NSString *)symbol title:(NSString *)title subtitle:(NSString *)subtitle {
    _iconView.image = [UIImage systemImageNamed:symbol ?: @"tray"];
    _titleLabel.text = title;
    _subtitleLabel.text = subtitle;
}

- (void)setActionTitle:(NSString *)title {
    _actionButton.hidden = (title.length == 0);
    [_actionButton setTitle:title forState:UIControlStateNormal];
}

- (void)dpo_actionTapped {
    if (self.onAction) self.onAction();
}

@end

#pragma mark - DPOToast

static __weak UIView *DPOCurrentToast = nil;

@implementation DPOToast

+ (void)show:(NSString *)message {
    if (message.length == 0) return;

    DPORunOnMain(^{
        UIWindow *window = DPOKeyWindow();
        if (window == nil) return;

        [DPOCurrentToast removeFromSuperview];

        UIView *pill = [[UIView alloc] init];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        pill.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        pill.layer.cornerRadius = 18;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.userInteractionEnabled = NO;
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeScale(0.94, 0.94);

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = message;
        label.font = DPOFont(13, UIFontWeightMedium);
        label.textColor = UIColor.whiteColor;
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        [pill addSubview:label];

        [window addSubview:pill];
        DPOCurrentToast = pill;

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:14],
            [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-14],
            [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:9],
            [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-9],

            [pill.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
            [pill.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-72],
            [pill.leadingAnchor constraintGreaterThanOrEqualToAnchor:window.leadingAnchor constant:40],
            [pill.trailingAnchor constraintLessThanOrEqualToAnchor:window.trailingAnchor constant:-40],
        ]];

        [UIView animateWithDuration:0.26
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            pill.alpha = 1.0;
            pill.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.28
                                  delay:1.7
                                options:UIViewAnimationOptionCurveEaseIn
                             animations:^{
                pill.alpha = 0.0;
                pill.transform = CGAffineTransformMakeScale(0.96, 0.96);
            } completion:^(BOOL done) {
                [pill removeFromSuperview];
            }];
        }];
    });
}

@end

#pragma mark - 插件卡片行

@interface DPOPluginGroupCell ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIView *iconBackground;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIImageView *chevronView;
@property (nonatomic, strong) UIButton *openButton;
@property (nonatomic, strong) UIStackView *textStack;
@property (nonatomic, strong) UIStackView *rowStack;
@property (nonatomic, assign) BOOL openable;
@end

@implementation DPOPluginGroupCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        
        _cardView = [[UIView alloc] init];
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        // 整块面板模式：行本身不再有卡片，只负责排版（原来的一卡一行已废弃）
        _cardView.backgroundColor = UIColor.clearColor;
        _cardView.layer.cornerRadius = 0.0;
        _cardView.layer.borderWidth = 0.0;
        _cardView.layer.shadowOpacity = 0.0;
        _cardView.clipsToBounds = NO;
        [self.contentView addSubview:_cardView];

        _iconBackground = [[UIView alloc] init];
        _iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
        _iconBackground.layer.cornerRadius = 11.0;
        _iconBackground.layer.cornerCurve = kCACornerCurveContinuous;
        _iconBackground.clipsToBounds = YES;
        [_cardView addSubview:_iconBackground];

        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = UIColor.whiteColor;
        [_iconBackground addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = DPOFont(14.5, UIFontWeightSemibold);
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.textAlignment = NSTextAlignmentLeft;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        
        _versionLabel = [[UILabel alloc] init];
        _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _versionLabel.font = DPOFontMonospaced(10.5, UIFontWeightMedium);
        _versionLabel.textColor = DPOColorTertiary();
        _versionLabel.textAlignment = NSTextAlignmentRight;
        [_versionLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                      forAxis:UILayoutConstraintAxisHorizontal];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.font = DPOFont(10.5, UIFontWeightRegular);
        _subtitleLabel.textColor = DPOColorSecondary();
        _subtitleLabel.textAlignment = NSTextAlignmentLeft;
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _chevronView = [[UIImageView alloc] init];
        _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        _chevronView.image = [UIImage systemImageNamed:@"chevron.right"];
        _chevronView.tintColor = [UIColor.tertiaryLabelColor colorWithAlphaComponent:0.6];
        _chevronView.contentMode = UIViewContentModeScaleAspectFit;
        [_cardView addSubview:_chevronView];

        _openButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _openButton.translatesAutoresizingMaskIntoConstraints = NO;
        _openButton.titleLabel.font = DPOFont(11.0, UIFontWeightMedium);
        _openButton.layer.cornerRadius = 11.0;
        _openButton.layer.cornerCurve = kCACornerCurveContinuous;
        _openButton.clipsToBounds = YES;
        [_openButton addTarget:self action:@selector(dpo_openTapped) forControlEvents:UIControlEventTouchUpInside];
        [_cardView addSubview:_openButton];

        
        _textStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _subtitleLabel ]];
        _textStack.axis = UILayoutConstraintAxisVertical;
        _textStack.alignment = UIStackViewAlignmentLeading;
        _textStack.spacing = 1.0;

        _rowStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _iconBackground, _textStack ]];
        _rowStack.translatesAutoresizingMaskIntoConstraints = NO;
        _rowStack.axis = UILayoutConstraintAxisHorizontal;
        _rowStack.alignment = UIStackViewAlignmentCenter;
        _rowStack.spacing = 10.0;
        [_cardView addSubview:_rowStack];
        [_cardView addSubview:_versionLabel];

        
        NSLayoutConstraint *cardWidth =
            [_cardView.widthAnchor constraintEqualToAnchor:self.contentView.widthAnchor constant:-32];
        cardWidth.priority = 999;

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_cardView.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor],
            [_cardView.widthAnchor constraintLessThanOrEqualToConstant:460],
            cardWidth,

            // 图标是 _rowStack 的 arrangedSubview，横向位置由 stack 的 leading 决定。
            // 这里不能再给 icon 单独钉一条 leading，否则 16 与 stack 的 16 冲突时会
            // 触发 UITableViewCell 每次布局的 "Unable to simultaneously satisfy constraints"。
            [_iconBackground.widthAnchor constraintEqualToConstant:34],
            [_iconBackground.heightAnchor constraintEqualToConstant:34],

            [_iconView.centerXAnchor constraintEqualToAnchor:_iconBackground.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconBackground.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:18],
            [_iconView.heightAnchor constraintEqualToConstant:18],

            
            [_rowStack.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16],
            [_rowStack.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_rowStack.trailingAnchor constraintLessThanOrEqualToAnchor:_versionLabel.leadingAnchor constant:-10],

            [_versionLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-12],
            [_versionLabel.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],

            [_chevronView.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-12],
            [_chevronView.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_chevronView.widthAnchor constraintEqualToConstant:7],
            [_chevronView.heightAnchor constraintEqualToConstant:12],

            [_openButton.trailingAnchor constraintEqualToAnchor:_chevronView.leadingAnchor constant:-8],
            [_openButton.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_openButton.widthAnchor constraintEqualToConstant:50],
            [_openButton.heightAnchor constraintEqualToConstant:24],
        ]];
    }
    return self;
}

- (void)configureWithGroup:(DPOPluginGroup *)group expanded:(BOOL)expanded {
    NSString *name = group.name.length > 0 ? group.name : @"未命名插件";
    self.titleLabel.text = name;

    
    NSString *versionText = group.version.length > 0
                                ? [NSString stringWithFormat:@"v%@", group.version]
                                : @"";
    self.versionLabel.text = versionText;
    self.versionLabel.hidden = (versionText.length == 0);

    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (DPOFeature *feature in group.features) {
        NSString *title = [feature.title stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (title.length == 0) continue;
        if ([title caseInsensitiveCompare:name] == NSOrderedSame) continue;   
        if ([titles containsObject:title]) continue;
        [titles addObject:title];
        if (titles.count >= 2) break;
    }
    
    self.subtitleLabel.text = [titles componentsJoinedByString:@" / "];
    self.subtitleLabel.hidden = (titles.count == 0);

    NSUInteger seed = labs((long)[group.imagePath hash]) + group.name.length;
    NSArray<UIColor *> *colors = DPOAvatarColors(seed);

    UIImage *pluginIcon = nil;
    if (group.iconName.length > 0) {
        pluginIcon = [UIImage imageNamed:group.iconName];
    }
    if (pluginIcon != nil) {
        self.iconBackground.backgroundColor = UIColor.clearColor;
        self.iconView.image = pluginIcon;
        self.iconView.tintColor = nil;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        
        UIColor *fill = colors.count > 1 ? colors[1] : colors.firstObject;
        self.iconBackground.backgroundColor = fill ?: DPOColorAccent();
        self.iconView.image = [UIImage systemImageNamed:@"puzzlepiece.extension.fill"];
        self.iconView.tintColor = UIColor.whiteColor;
    }

    BOOL openable = NO;
    for (DPOFeature *feature in group.features) {
        if (!feature.isSwitch && feature.item != nil) {
            openable = YES;
            break;
        }
    }
    self.openable = openable;
    
    self.openButton.hidden = YES;
    self.chevronView.hidden = YES;
    [self.openButton setTitle:(openable ? @"打开" : @"不可用") forState:UIControlStateNormal];
    self.openButton.enabled = openable;
    self.openButton.backgroundColor = openable
        ? [DPOColorAccent() colorWithAlphaComponent:0.14]
        : [[UIColor tertiarySystemFillColor] colorWithAlphaComponent:0.7];
    [self.openButton setTitleColor:(openable ? DPOColorAccent() : DPOColorTertiary())
                          forState:UIControlStateNormal];

    self.chevronView.transform = expanded ? CGAffineTransformMakeRotation(M_PI_2)
                                          : CGAffineTransformIdentity;
}

- (void)dpo_openTapped {
    if (self.openable && self.onOpen) self.onOpen();
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onOpen = nil;
    self.cardView.alpha = 1.0;
    self.cardView.transform = CGAffineTransformIdentity;
    // 面板模式下卡片本身必须透明，否则复用的 cell 会把整行刷成白块
    self.cardView.backgroundColor = UIColor.clearColor;
    self.subtitleLabel.hidden = NO;
    self.versionLabel.hidden = NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    
    CGRect cardBounds = self.cardView.bounds;
    if (cardBounds.size.width > 0.0 && cardBounds.size.height > 0.0) {
        self.cardView.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:cardBounds cornerRadius:16.0].CGPath;
    } else {
        self.cardView.layer.shadowPath = nil;
    }
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];

    
    BOOL reduced = UIAccessibilityIsReduceMotionEnabled();
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (highlighted && !reduced) transform = CGAffineTransformMakeScale(0.985, 0.985);
    UIColor *fill = highlighted ? [UIColor colorWithWhite:1.0 alpha:0.16] : UIColor.clearColor;

    if (reduced) {
        self.cardView.transform = transform;
        self.cardView.backgroundColor = fill;
        return;
    }
    [UIView animateWithDuration:0.18 animations:^{
        self.cardView.transform = transform;
        self.cardView.backgroundColor = fill;
    }];
}

@end

#pragma mark - DPOGlassPopup

static __weak UIView *DPOCurrentGlassPopup = nil;

@implementation DPOGlassPopup

+ (void)showTitle:(NSString *)title message:(NSString *)message {
    if (title.length == 0) return;

    DPORunOnMain(^{
        UIWindow *window = DPOKeyWindow();
        if (window == nil) return;

        [DPOCurrentGlassPopup removeFromSuperview];

        UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.05];
        overlay.alpha = 0.0;
        [window addSubview:overlay];
        DPOCurrentGlassPopup = overlay;

        // 点空白处关闭
        UIControl *backdrop = [[UIControl alloc] initWithFrame:overlay.bounds];
        backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        backdrop.backgroundColor = UIColor.clearColor;
        [backdrop addTarget:self action:@selector(dpo_dismiss) forControlEvents:UIControlEventTouchUpInside];
        [overlay addSubview:backdrop];

        // 阴影放在外层容器上，玻璃本体自己负责圆角裁剪
        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = UIColor.clearColor;
        card.layer.shadowColor = UIColor.blackColor.CGColor;
        card.layer.shadowOpacity = 0.16;
        card.layer.shadowRadius = 30.0;
        card.layer.shadowOffset = CGSizeMake(0, 14);
        card.alpha = 0.0;
        card.transform = CGAffineTransformMakeScale(0.9, 0.9);
        [overlay addSubview:card];

        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.layer.cornerRadius = 26.0;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = YES;
        glass.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        glass.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.62].CGColor;
        [card addSubview:glass];

        // 清透感：极淡白 tint
        UIView *tint = [[UIView alloc] init];
        tint.translatesAutoresizingMaskIntoConstraints = NO;
        tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        tint.userInteractionEnabled = NO;
        [glass.contentView addSubview:tint];

        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = title;
        titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
        titleLabel.textColor = UIColor.labelColor;
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.numberOfLines = 1;

        UILabel *messageLabel = [[UILabel alloc] init];
        messageLabel.text = message;
        messageLabel.font = DPOFont(12.5, UIFontWeightRegular);
        messageLabel.textColor = DPOColorSecondary();
        messageLabel.textAlignment = NSTextAlignmentCenter;
        messageLabel.numberOfLines = 0;

        UIButton *actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [actionButton setTitle:@"知道啦" forState:UIControlStateNormal];
        actionButton.titleLabel.font = DPOFont(13.0, UIFontWeightMedium);
        [actionButton setTitleColor:DPOColorAccent() forState:UIControlStateNormal];
        actionButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        actionButton.layer.cornerRadius = 12.0;
        actionButton.layer.cornerCurve = kCACornerCurveContinuous;
        actionButton.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        actionButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.75].CGColor;
        [actionButton addTarget:self action:@selector(dpo_dismiss) forControlEvents:UIControlEventTouchUpInside];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, messageLabel, actionButton ]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentFill;
        stack.spacing = 10.0;
        [stack setCustomSpacing:14.0 afterView:messageLabel];
        [glass.contentView addSubview:stack];

        NSLayoutConstraint *cardWidth = [card.widthAnchor constraintEqualToConstant:272.0];

        [NSLayoutConstraint activateConstraints:@[
            [glass.topAnchor constraintEqualToAnchor:card.topAnchor],
            [glass.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],

            [tint.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
            [tint.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
            [tint.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor],
            [tint.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor],

            [stack.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:24.0],
            [stack.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:22.0],
            [stack.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-22.0],
            [stack.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-20.0],

            [actionButton.heightAnchor constraintEqualToConstant:38.0],

            cardWidth,
            [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
            [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-6.0],
        ]];

        [window layoutIfNeeded];
        card.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:card.bounds cornerRadius:26.0].CGPath;

        [UIView animateWithDuration:0.22 animations:^{
            overlay.alpha = 1.0;
        }];

        [UIView animateWithDuration:0.44
                              delay:0.0
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            card.alpha = 1.0;
            card.transform = CGAffineTransformIdentity;
        } completion:nil];
    });
}

+ (void)dpo_dismiss {
    UIView *overlay = DPOCurrentGlassPopup;
    if (overlay == nil) return;
    DPOCurrentGlassPopup = nil;

    for (UIView *subview in overlay.subviews) {
        if (subview.layer.shadowOpacity > 0.0) {
            [UIView animateWithDuration:0.16 animations:^{
                subview.alpha = 0.0;
                subview.transform = CGAffineTransformMakeScale(0.94, 0.94);
            }];
        }
    }
    [UIView animateWithDuration:0.2
                          delay:0.04
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

@end

#pragma mark - 搜索结果行

@interface DPOResultCell ()
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *iconTile;
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *locationLabel;
@property (nonatomic, strong) UIImageView *chevronView;
@property (nonatomic, strong) UIView *separator;
@end

@implementation DPOResultCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        [self dpo_setup];
    }
    return self;
}

- (void)dpo_setup {
    _card = [[UIView alloc] init];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.backgroundColor = UIColor.whiteColor;
    _card.layer.cornerRadius = 12.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    [self.contentView addSubview:_card];

    _iconTile = [[UIView alloc] init];
    _iconTile.translatesAutoresizingMaskIntoConstraints = NO;
    _iconTile.layer.cornerRadius = 8.0;
    _iconTile.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_iconTile];

    _iconLabel = [[UILabel alloc] init];
    _iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _iconLabel.font = DPOFont(14.0, UIFontWeightSemibold);
    _iconLabel.textAlignment = NSTextAlignmentCenter;
    [_iconTile addSubview:_iconLabel];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = DPOFont(16.0, UIFontWeightRegular);
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.numberOfLines = 1;
    [_card addSubview:_titleLabel];

    _locationLabel = [[UILabel alloc] init];
    _locationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _locationLabel.font = DPOFont(11.5, UIFontWeightRegular);
    _locationLabel.textColor = DPOColorTertiary();
    _locationLabel.textAlignment = NSTextAlignmentRight;
    _locationLabel.numberOfLines = 1;
    _locationLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    [_locationLabel setContentCompressionResistancePriority:749 forAxis:UILayoutConstraintAxisHorizontal];
    [_card addSubview:_locationLabel];

    _chevronView = [[UIImageView alloc] initWithImage:
                        [UIImage systemImageNamed:@"chevron.right"
                                withConfiguration:[UIImageSymbolConfiguration
                                                     configurationWithPointSize:12.0
                                                     weight:UIImageSymbolWeightMedium]]];
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    _chevronView.tintColor = DPOColorTertiary();
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [_chevronView setContentHuggingPriority:UILayoutPriorityRequired
                                    forAxis:UILayoutConstraintAxisHorizontal];
    [_card addSubview:_chevronView];

    _separator = [[UIView alloc] init];
    _separator.translatesAutoresizingMaskIntoConstraints = NO;
    _separator.backgroundColor = DPOColorSeparator();
    [_card addSubview:_separator];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [_iconTile.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:14],
        [_iconTile.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_iconTile.widthAnchor constraintEqualToConstant:28],
        [_iconTile.heightAnchor constraintEqualToConstant:28],

        [_iconLabel.centerXAnchor constraintEqualToAnchor:_iconTile.centerXAnchor],
        [_iconLabel.centerYAnchor constraintEqualToAnchor:_iconTile.centerYAnchor],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconTile.trailingAnchor constant:11],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_titleLabel.topAnchor constraintGreaterThanOrEqualToAnchor:_card.topAnchor constant:13],
        [_titleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-13],

        [_chevronView.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],
        [_chevronView.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:10],
        [_chevronView.heightAnchor constraintEqualToConstant:14],

        [_locationLabel.trailingAnchor constraintEqualToAnchor:_chevronView.leadingAnchor constant:-8],
        [_locationLabel.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_locationLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:10],

        [_separator.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_separator.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
        [_separator.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
        [_separator.heightAnchor constraintEqualToConstant:0.5],
    ]];

    NSLayoutConstraint *locationMax = [_locationLabel.widthAnchor
        constraintLessThanOrEqualToAnchor:_card.widthAnchor multiplier:0.46];
    locationMax.priority = 750;
    locationMax.active = YES;

    NSLayoutConstraint *titleMax = [_titleLabel.widthAnchor
        constraintLessThanOrEqualToAnchor:_card.widthAnchor multiplier:0.62];
    titleMax.priority = 751;
    titleMax.active = YES;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.titleLabel.attributedText = nil;
    self.locationLabel.text = nil;
}

- (void)configureTitle:(NSString *)title
              location:(NSString *)location
            pluginName:(NSString *)pluginName
                 query:(NSString *)query
            firstInSet:(BOOL)firstInSet
             lastInSet:(BOOL)lastInSet {

    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:title ?: @""];
    [text addAttributes:@{ NSFontAttributeName: DPOFont(16.0, UIFontWeightRegular),
                           NSForegroundColorAttributeName: UIColor.labelColor }
                  range:NSMakeRange(0, text.length)];

    NSRange match = DPOMatchRangeInString(title, query);
    if (match.location != NSNotFound) {
        // 不用主题红：红色在这套设计里是「危险」色，命中词用加粗 + 极淡底就够。
        [text addAttributes:@{ NSFontAttributeName: DPOFont(16.0, UIFontWeightSemibold),
                               NSForegroundColorAttributeName: UIColor.labelColor,
                               NSBackgroundColorAttributeName:
                                   [UIColor.labelColor colorWithAlphaComponent:0.06] }
                      range:match];
    }
    self.titleLabel.attributedText = text;
    self.locationLabel.text = location;

    NSString *name = pluginName.length > 0 ? pluginName : @"·";
    NSInteger seed = 0;
    for (NSUInteger index = 0; index < name.length; index++) {
        seed += (NSInteger)[name characterAtIndex:index];
    }
    NSArray<UIColor *> *palette = DPOAvatarColors(seed);
    UIColor *tint = palette.firstObject ?: DPOColorAccent();
    self.iconTile.backgroundColor = [tint colorWithAlphaComponent:0.14];
    self.iconLabel.textColor = tint;
    NSRange firstRange = [name rangeOfComposedCharacterSequenceAtIndex:0];
    self.iconLabel.text = [name substringWithRange:firstRange];

    // 中间行必须是直角：否则相邻行之间会露出四个圆角缺口（第一版就是这么翻车的）。
    CACornerMask mask = 0;
    if (firstInSet) mask |= kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    if (lastInSet) mask |= kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    if (firstInSet && lastInSet) {
        mask = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    }
    self.card.layer.cornerRadius = 12.0;
    self.card.layer.maskedCorners = mask;
    self.separator.hidden = lastInSet;
}

@end
