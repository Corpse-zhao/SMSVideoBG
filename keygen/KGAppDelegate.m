#import "KGAppDelegate.h"
#import "KGCore.h"
#import <objc/runtime.h>

// ============================================================
// 激活码签发 App (v1.0)
//  - 目标设备码 (控制 App 授权页复制) / 通用码
//  - 有效期: 按天 (快捷 7/30/90/365/730) 或永久
//  - 一键签发 + 自动复制 / 分享 / 本地验签
//  - 签名密钥可改 (默认编译期注入, 与插件共用同一 GitHub Secret)
//  - 签发历史 (本机保存, 点击复制)
// ============================================================

static UIColor *KGAccent(void)  { return [UIColor colorWithRed:0.98 green:0.27 blue:0.51 alpha:1.0]; }
static UIColor *KGAccent2(void) { return [UIColor colorWithRed:0.63 green:0.32 blue:0.98 alpha:1.0]; }
static UIColor *KGCardColor(void) { return [UIColor secondarySystemGroupedBackgroundColor]; }

static NSString * const KGPrefSecret  = @"kg_secret";
static NSString * const KGPrefHistory = @"kg_history";

#pragma mark - 渐变视图

@interface KGGradientView : UIView
@end
@implementation KGGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        CAGradientLayer *g = (CAGradientLayer *)self.layer;
        g.colors = @[(__bridge id)KGAccent().CGColor, (__bridge id)KGAccent2().CGColor];
        g.startPoint = CGPointMake(0.0, 0.0);
        g.endPoint   = CGPointMake(1.0, 1.0);
        g.cornerRadius = 22;
        self.layer.masksToBounds = YES;
    }
    return self;
}
@end

#pragma mark - 小工具

static UILabel *KGLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UIButton *KGButton(NSString *title, UIColor *bg, UIColor *fg, CGFloat height) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.backgroundColor = bg;
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = height / 2.0;
    b.layer.masksToBounds = YES;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:height].active = YES;
    return b;
}

// 卡片容器 (含标题), 通过 outStack 拿内部竖排堆栈
static UIView *KGCard(NSString *title, UIStackView **outStack) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = KGCardColor();
    card.layer.cornerRadius = 18;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    if (title.length) {
        UILabel *t = KGLabel(title, 13, UIFontWeightSemibold,
                             [UIColor secondaryLabelColor]);
        [stack addArrangedSubview:t];
    }
    if (outStack) *outStack = stack;
    return card;
}

// 一行: 左标题 + 右控件 (+ 下方小字说明)
static UIView *KGRow(NSString *label, UIView *trailing, NSString *hint) {
    UIStackView *v = [[UIStackView alloc] initWithFrame:CGRectZero];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 4;

    UIStackView *h = [[UIStackView alloc] initWithFrame:CGRectZero];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.spacing = 10;
    h.alignment = UIStackViewAlignmentCenter;

    UILabel *l = KGLabel(label, 16, UIFontWeightRegular, [UIColor labelColor]);
    [h addArrangedSubview:l];
    UIView *spring = [[UIView alloc] initWithFrame:CGRectZero];
    [h addArrangedSubview:spring];
    [h addArrangedSubview:trailing];
    [v addArrangedSubview:h];

    if (hint.length) [v addArrangedSubview:KGLabel(hint, 12.5, UIFontWeightRegular, [UIColor tertiaryLabelColor])];
    return v;
}

static UITextField *KGField(NSString *placeholder, CGFloat fontSize, BOOL digits) {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectZero];
    f.placeholder = placeholder;
    f.font = [UIFont monospacedSystemFontOfSize:fontSize weight:UIFontWeightMedium];
    f.textColor = [UIColor labelColor];
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    f.spellCheckingType = UITextSpellCheckingTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
    f.layer.cornerRadius = 10;
    f.layer.masksToBounds = YES;
    f.keyboardType = digits ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable;
    f.returnKeyType = UIReturnKeyDone;
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    f.leftView = pad;
    f.leftViewMode = UITextFieldViewModeAlways;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    return f;
}

#pragma mark - 主界面

@interface KGViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITextField *deviceField;
@property (nonatomic, strong) UISwitch *universalSwitch;
@property (nonatomic, strong) UISwitch *foreverSwitch;
@property (nonatomic, strong) UITextField *daysField;
@property (nonatomic, strong) UITextField *secretField;
@property (nonatomic, strong) UILabel *fpLabel;
@property (nonatomic, strong) UILabel *secretWarnLabel;
@property (nonatomic, strong) UILabel *codeLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *clipBtn;
@property (nonatomic, strong) UIButton *shareBtn;
@property (nonatomic, strong) UIButton *verifyBtn;
@property (nonatomic, strong) UIStackView *historyStack;
@property (nonatomic, strong) UIView *historyCard;
@end

@implementation KGViewController

- (NSString *)currentSecret {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:KGPrefSecret];
    return (s.length > 0) ? s : KGCompiledSecret();
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scroll];

    UIStackView *root = [[UIStackView alloc] initWithFrame:CGRectZero];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 14;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [root.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:16],
        [root.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [root.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [root.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    // 收键盘 (不吞按钮点击)
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [_scroll addGestureRecognizer:tap];

    [root addArrangedSubview:[self heroCard]];
    [root addArrangedSubview:[self deviceCard]];
    [root addArrangedSubview:[self termCard]];
    [root addArrangedSubview:[self resultCard]];
    [root addArrangedSubview:[self secretCard]];
    [root addArrangedSubview:[self buildHistoryCard]];
    [root addArrangedSubview:[self footerLabel]];
    [self refreshSecretUI];
    [self refreshHistory];
}

- (void)dismissKeyboard { [self.view endEditing:YES]; }

#pragma mark 各卡片

- (UIView *)heroCard {
    KGGradientView *hero = [[KGGradientView alloc] initWithFrame:CGRectZero];
    hero.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *v = [[UIStackView alloc] initWithFrame:CGRectZero];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 4;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:hero.topAnchor constant:22],
        [v.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:20],
        [v.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-20],
        [v.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-22],
        [hero.heightAnchor constraintEqualToConstant:112],
    ]];

    UILabel *t = KGLabel(@"激活码签发", 27, UIFontWeightBold, UIColor.whiteColor);
    UILabel *s = KGLabel(@"信息视频背景 · 离线授权 · 设备绑定", 13.5, UIFontWeightMedium,
                         [UIColor colorWithWhite:1 alpha:0.88]);
    [v addArrangedSubview:t];
    [v addArrangedSubview:s];
    return hero;
}

- (UIView *)deviceCard {
    UIStackView *stack;
    UIView *card = KGCard(@"目标设备", &stack);

    _deviceField = KGField(@"ABCD-EFGH", 17, NO);
    _deviceField.delegate = self;
    [_deviceField.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:KGRow(@"设备码", _deviceField, @"在客户手机上打开控制 App → 授权 → 复制设备码")];

    _universalSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _universalSwitch.onTintColor = KGAccent();
    [_universalSwitch addTarget:self action:@selector(universalToggled:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:KGRow(@"通用码 (不绑设备)", _universalSwitch, @"任何设备都能用 —— 泄漏即全线可用, 慎用")];
    return card;
}

- (UIView *)termCard {
    UIStackView *stack;
    UIView *card = KGCard(@"有效期", &stack);

    _foreverSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _foreverSwitch.onTintColor = KGAccent();
    [_foreverSwitch addTarget:self action:@selector(foreverToggled:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:KGRow(@"永久有效", _foreverSwitch, nil)];

    _daysField = KGField(@"365", 17, YES);
    _daysField.delegate = self;
    _daysField.text = @"365";
    _daysField.textAlignment = NSTextAlignmentRight;
    [_daysField.widthAnchor constraintEqualToConstant:110].active = YES;
    [_daysField.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:KGRow(@"天数", _daysField, nil)];

    UIStackView *chips = [[UIStackView alloc] initWithFrame:CGRectZero];
    chips.axis = UILayoutConstraintAxisHorizontal;
    chips.distribution = UIStackViewDistributionFillEqually;
    chips.spacing = 8;
    for (NSNumber *d in @[@7, @30, @90, @365, @730]) {
        UIButton *b = KGButton([NSString stringWithFormat:@"%@天", d],
                               [UIColor tertiarySystemFillColor], [UIColor labelColor], 34);
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        b.layer.cornerRadius = 10;
        [chips addArrangedSubview:b];
    }
    [stack addArrangedSubview:chips];
    [self foreverToggled:nil];
    return card;
}

- (UIView *)resultCard {
    UIStackView *stack;
    UIView *card = KGCard(@"签发", &stack);

    UIButton *gen = KGButton(@"生成激活码", KGAccent(), UIColor.whiteColor, 48);
    gen.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [gen addTarget:self action:@selector(generateTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:gen];

    _codeLabel = KGLabel(@"—", 21, UIFontWeightBold, [UIColor labelColor]);
    _codeLabel.font = [UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightBold];
    _codeLabel.textAlignment = NSTextAlignmentCenter;
    _codeLabel.lineBreakMode = NSLineBreakByCharWrapping;
    _codeLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *copyTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyTapped)];
    [_codeLabel addGestureRecognizer:copyTap];
    [stack addArrangedSubview:_codeLabel];

    _statusLabel = KGLabel(@"填好设备码和有效期后点「生成激活码」", 13, UIFontWeightRegular, [UIColor secondaryLabelColor]);
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:_statusLabel];

    UIStackView *btns = [[UIStackView alloc] initWithFrame:CGRectZero];
    btns.axis = UILayoutConstraintAxisHorizontal;
    btns.distribution = UIStackViewDistributionFillEqually;
    btns.spacing = 8;
    _clipBtn = KGButton(@"复制", [UIColor tertiarySystemFillColor], [UIColor labelColor], 40);
    _shareBtn = KGButton(@"分享", [UIColor tertiarySystemFillColor], [UIColor labelColor], 40);
    _verifyBtn = KGButton(@"验签", [UIColor tertiarySystemFillColor], [UIColor labelColor], 40);
    [_clipBtn addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
    [_shareBtn addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [_verifyBtn addTarget:self action:@selector(verifyTapped) forControlEvents:UIControlEventTouchUpInside];
    [btns addArrangedSubview:_clipBtn];
    [btns addArrangedSubview:_shareBtn];
    [btns addArrangedSubview:_verifyBtn];
    [stack addArrangedSubview:btns];
    return card;
}

- (UIView *)secretCard {
    UIStackView *stack;
    UIView *card = KGCard(@"签名密钥", &stack);

    _secretField = KGField(@"签名密钥", 13, NO);
    _secretField.delegate = self;
    _secretField.secureTextEntry = NO;
    [_secretField.heightAnchor constraintEqualToConstant:40].active = YES;
    [stack addArrangedSubview:_secretField];

    UILabel *fpTitle = KGLabel(@"密钥指纹", 14, UIFontWeightRegular, [UIColor labelColor]);
    _fpLabel = KGLabel(@"-", 14, UIFontWeightSemibold, [UIColor secondaryLabelColor]);
    _fpLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
    UIStackView *fpRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    fpRow.axis = UILayoutConstraintAxisHorizontal;
    fpRow.spacing = 8;
    [fpRow addArrangedSubview:fpTitle];
    [fpRow addArrangedSubview:_fpLabel];
    [stack addArrangedSubview:fpRow];

    _secretWarnLabel = KGLabel(@"", 12.5, UIFontWeightMedium,
                               [UIColor systemOrangeColor]);
    _secretWarnLabel.hidden = YES;
    [stack addArrangedSubview:_secretWarnLabel];

    UIButton *reset = KGButton(@"重置为内置密钥", [UIColor tertiarySystemFillColor], [UIColor labelColor], 38);
    reset.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    [reset addTarget:self action:@selector(resetSecretTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:reset];

    [stack addArrangedSubview:KGLabel(@"必须与插件编译时注入的密钥一致 (GitHub Secret: SVB_LICENSE_SECRET), 否则客户会提示「激活码无效」。修改后自动保存。", 12.5, UIFontWeightRegular, [UIColor tertiaryLabelColor])];
    return card;
}

- (UILabel *)footerLabel {
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0";
    UILabel *f = KGLabel([NSString stringWithFormat:@"信息视频背景 · 激活码签发 v%@ · 板栗仁", ver],
                         12, UIFontWeightRegular, [UIColor tertiaryLabelColor]);
    f.textAlignment = NSTextAlignmentCenter;
    return f;
}

#pragma mark 历史

- (UIView *)buildHistoryCard {
    UIStackView *stack;
    UIView *card = KGCard(@"签发历史 (点击复制, 最多留 15 条)", &stack);
    _historyCard = card;
    _historyStack = stack;
    return card;
}

- (NSArray *)historyItems {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:KGPrefHistory];
    return a ? a : @[];
}

- (void)refreshHistory {
    NSArray *items = [self historyItems];
    while (_historyStack.arrangedSubviews.count > 1) {
        UIView *v = _historyStack.arrangedSubviews.lastObject;
        [_historyStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (!items.count) {
        UILabel *empty = KGLabel(@"还没有签发记录", 13, UIFontWeightRegular, [UIColor tertiaryLabelColor]);
        [_historyStack addArrangedSubview:empty];
        return;
    }
    for (NSDictionary *d in items) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
        row.layer.cornerRadius = 12;

        UIStackView *v = [[UIStackView alloc] initWithFrame:CGRectZero];
        v.axis = UILayoutConstraintAxisVertical;
        v.spacing = 2;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
            [v.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
            [v.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
            [v.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8],
        ]];

        NSString *who = [d objectForKey:@"universal"] ? @"通用码" :
            [NSString stringWithFormat:@"设备 %@", [d objectForKey:@"device"] ?: @"-"];
        UILabel *l1 = KGLabel([NSString stringWithFormat:@"%@ · %@", who, [d objectForKey:@"exp"] ?: @"-"],
                              12.5, UIFontWeightMedium, [UIColor secondaryLabelColor]);
        UILabel *l2 = KGLabel([d objectForKey:@"code"] ?: @"", 13.5, UIFontWeightSemibold, [UIColor labelColor]);
        l2.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
        [v addArrangedSubview:l1];
        [v addArrangedSubview:l2];

        NSString *code = [d objectForKey:@"code"];
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(historyTapped:)];
        [row addGestureRecognizer:t];
        objc_setAssociatedObject(row, "kg_code", code, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [_historyStack addArrangedSubview:row];
    }
}

- (void)historyTapped:(UITapGestureRecognizer *)g {
    NSString *code = objc_getAssociatedObject(g.view, "kg_code");
    if (code.length) [self copyText:code];
}

- (void)saveHistoryCode:(NSString *)code device:(NSString *)device universal:(BOOL)uni exp:(NSString *)exp {
    NSMutableArray *items = [[self historyItems] mutableCopy];
    [items insertObject:@{@"code": code, @"device": device ?: @"", @"universal": @(uni), @"exp": exp ?: @"", @"ts": @([[NSDate date] timeIntervalSince1970])}
                 atIndex:0];
    while (items.count > 15) [items removeLastObject];
    [[NSUserDefaults standardUserDefaults] setObject:items forKey:KGPrefHistory];
    [self refreshHistory];
}

#pragma mark 行为

- (void)universalToggled:(UISwitch *)s { (void)s; }

- (void)foreverToggled:(UISwitch *)s {
    _daysField.enabled = !_foreverSwitch.on;
    _daysField.alpha = _foreverSwitch.on ? 0.4 : 1.0;
}

- (void)chipTapped:(UIButton *)b {
    NSString *t = [b.currentTitle stringByReplacingOccurrencesOfString:@"天" withString:@""];
    _foreverSwitch.on = NO;
    [self foreverToggled:nil];
    _daysField.text = t;
}

- (void)generateTapped {
    [self.view endEditing:YES];
    NSString *secret = _secretField.text.length ? _secretField.text : [self currentSecret];
    NSString *device = _deviceField.text;
    BOOL uni = _universalSwitch.on;
    BOOL forever = _foreverSwitch.on;
    NSInteger days = [_daysField.text integerValue];

    NSString *exp = nil, *err = nil;
    NSString *code = KGBuildCode(secret, device, uni, forever, days, &exp, &err);
    if (!code) {
        _codeLabel.text = @"—";
        _statusLabel.text = [NSString stringWithFormat:@"⚠️ %@", err ?: @"生成失败"];
        _statusLabel.textColor = [UIColor systemOrangeColor];
        return;
    }
    _codeLabel.text = code;
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.text = [NSString stringWithFormat:@"%@ · 有效期至 %@",
                         uni ? @"通用码" : [NSString stringWithFormat:@"设备 %@", KGDeviceNormalize(device) ?: device ?: @"-"],
                         exp ?: @"-"];
    [self copyText:code];
    [self saveHistoryCode:code device:KGDeviceNormalize(device) universal:uni exp:exp];
}

- (void)copyTapped {
    NSString *c = _codeLabel.text;
    if (c.length == 29) [self copyText:c];
}

- (void)copyText:(NSString *)text {
    [UIPasteboard generalPasteboard].string = text;
    NSString *old = _clipBtn.currentTitle;
    [_clipBtn setTitle:@"已复制 ✓" forState:UIControlStateNormal];
    [_clipBtn setTitleColor:KGAccent() forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self.clipBtn currentTitle] && [self.clipBtn.currentTitle containsString:@"已复制"]) {
            [self.clipBtn setTitle:old forState:UIControlStateNormal];
            [self.clipBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        }
    });
}

- (void)shareTapped {
    NSString *code = _codeLabel.text;
    if (code.length != 29) return;
    NSString *deviceLine = _universalSwitch.on ? @"通用码" :
        [NSString stringWithFormat:@"设备码 %@", _deviceField.text ?: @""];
    NSString *text = [NSString stringWithFormat:@"【信息视频背景】激活码\n%@\n%@\n有效期: %@\n在控制 App → 授权 中输入", code, deviceLine, _statusLabel.text ?: @""];
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)verifyTapped {
    [self.view endEditing:YES];
    NSString *secret = _secretField.text.length ? _secretField.text : [self currentSecret];
    NSString *code = _codeLabel.text;
    if (code.length != 29) {
        _statusLabel.text = @"⚠️ 请先生成或粘贴一枚激活码";
        _statusLabel.textColor = [UIColor systemOrangeColor];
        return;
    }
    NSString *res = KGVerifyCode(secret, code, _deviceField.text);
    _statusLabel.text = res;
    _statusLabel.textColor = [res hasPrefix:@"✓"] ? [UIColor systemGreenColor] : [UIColor systemRedColor];
}

- (void)resetSecretTapped {
    _secretField.text = KGCompiledSecret();
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:KGPrefSecret];
    [self refreshSecretUI];
}

- (void)refreshSecretUI {
    if (_secretField.text.length == 0) _secretField.text = [self currentSecret];
    NSString *s = _secretField.text.length ? _secretField.text : [self currentSecret];
    _fpLabel.text = KGSecretFingerprint(s);
    BOOL isFallback = [s isEqualToString:KGCompiledSecret()] &&
                      [s isEqualToString:@"SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"];
    _secretWarnLabel.hidden = !isFallback;
    _secretWarnLabel.text = isFallback ?
        @"⚠️ 当前是内置兜底密钥 —— 插件若用 Secret 编译, 签出的码不会被识别" : @"";
}

#pragma mark UITextFieldDelegate

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == _secretField) {
        NSString *t = [textField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:t forKey:KGPrefSecret];
        }
        [self refreshSecretUI];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

#pragma mark - AppDelegate

@implementation KGAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[KGViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
