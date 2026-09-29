#import "KGAppDelegate.h"
#import "KGAuth.h"
#import "KGAuthClient.h"
#import <objc/runtime.h>

// ============================================================
// 授权签发 App v2.0.0 —— UDID 白名单制
//   ① 客户在控制App「授权」页复制本机 UDID 发给你;
//   ② 你把 UDID 粘进来 (可加备注 / 选有效期) 点「签发授权」;
//   ③ 名单推到远端 auth.json, 对方插件 30 分钟内自动生效;
//   ④ 在名单里删掉某台 UDID —— 对方设备最多 30 分钟掉授权。
//
//   仓库里只存 UDID 的 SHA256 指纹 (32 位 HEX), 不存 UDID 原文。
// ============================================================

static NSString * const KGPrefDevices = @"kg_devices";   // 本机授权名单

static UIColor *KGAccent(void)   { return [UIColor colorWithRed:0.98 green:0.27 blue:0.51 alpha:1.0]; }
static UIColor *KGAccent2(void)  { return [UIColor colorWithRed:0.63 green:0.32 blue:0.98 alpha:1.0]; }
static UIColor *KGCardColor(void) { return [UIColor secondarySystemGroupedBackgroundColor]; }

static NSString *KGShortDateTime(NSTimeInterval ts) {
    if (ts <= 0) return @"-";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm";
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

static NSInteger KGDaysLeftForExp(uint32_t exp) {
    if (exp == KG_AUTH_FOREVER) return -1;
    uint32_t today = KGDayIndexFromNow(0);
    return (NSInteger)exp - (NSInteger)today;
}

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
    if (title.length)
        [stack addArrangedSubview:KGLabel(title, 13, UIFontWeightSemibold, [UIColor secondaryLabelColor])];
    if (outStack) *outStack = stack;
    return card;
}

static UIView *KGRow(NSString *label, UIView *trailing, NSString *hint) {
    UIStackView *v = [[UIStackView alloc] initWithFrame:CGRectZero];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 4;

    UIStackView *h = [[UIStackView alloc] initWithFrame:CGRectZero];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.spacing = 10;
    h.alignment = UIStackViewAlignmentCenter;

    [h addArrangedSubview:KGLabel(label, 16, UIFontWeightRegular, [UIColor labelColor])];
    [h addArrangedSubview:[[UIView alloc] initWithFrame:CGRectZero]];
    [h addArrangedSubview:trailing];
    [v addArrangedSubview:h];

    if (hint.length)
        [v addArrangedSubview:KGLabel(hint, 12.5, UIFontWeightRegular, [UIColor tertiaryLabelColor])];
    return v;
}

static UITextField *KGField(NSString *placeholder, CGFloat fontSize, BOOL digits) {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectZero];
    f.placeholder = placeholder;
    f.font = [UIFont monospacedSystemFontOfSize:fontSize weight:UIFontWeightMedium];
    f.textColor = [UIColor labelColor];
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.spellCheckingType = UITextSpellCheckingTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
    f.layer.cornerRadius = 10;
    f.layer.masksToBounds = YES;
    f.keyboardType = digits ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable;
    f.autocapitalizationType = digits ? UITextAutocapitalizationTypeNone
                                      : UITextAutocapitalizationTypeAllCharacters;
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
@property (nonatomic, strong) UITextField *udidField;
@property (nonatomic, strong) UITextField *noteField;
@property (nonatomic, strong) UITextField *daysField;
@property (nonatomic, strong) UISwitch *foreverSwitch;
@property (nonatomic, strong) UIButton *issueBtn;
@property (nonatomic, strong) UILabel *issueStatus;

@property (nonatomic, strong) UILabel *heroSub;
@property (nonatomic, strong) UIStackView *listStack;
@property (nonatomic, strong) UILabel *listStatus;

@property (nonatomic, strong) UITextField *tokenField;
@property (nonatomic, strong) UITextField *repoField;
@property (nonatomic, strong) UITextField *branchField;
@property (nonatomic, strong) UILabel *syncStatus;

// v2.1.0: Gitee(码云) —— 国内直连, 客户手机不挂代理也能拉到名单
@property (nonatomic, strong) UITextField *giteeTokenField;
@property (nonatomic, strong) UITextField *giteeRepoField;
@property (nonatomic, strong) UITextField *giteeBranchField;
@property (nonatomic, strong) UILabel *giteeStatus;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *devices;   // 本机名单
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *remoteMap;  // 远端名单键
@property (nonatomic, assign) NSTimeInterval lastSync;
@property (nonatomic, assign) BOOL pushing;

// v2.1.0 新增方法的前置声明 (定义在本类靠后位置)
- (void)refreshGiteeStatus;
- (void)saveGiteeSettings;
- (void)offlineTicket:(NSInteger)i;
- (void)pushAllWithCompletion:(void (^)(BOOL ok, NSString *msg))done;
- (void)pushTapped;
@end

@implementation KGViewController

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"授权签发";

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    UIStackView *root = [[UIStackView alloc] initWithFrame:CGRectZero];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 14;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:16],
        [root.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-16],
        [root.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-28],
        [root.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-32],
    ]];

    [root addArrangedSubview:[self heroCard]];
    [root addArrangedSubview:[self issueCard]];
    [root addArrangedSubview:[self listCard]];
    [root addArrangedSubview:[self giteeCard]];
    [root addArrangedSubview:[self syncCard]];
    [root addArrangedSubview:[self secretCard]];
    [root addArrangedSubview:[self footerLabel]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [_scroll addGestureRecognizer:tap];

    [self refreshList];
    [self refreshHero];
    [self pullRemoteQuietly];
}

- (void)dismissKeyboard { [self.view endEditing:YES]; }

#pragma mark 卡片

- (UIView *)heroCard {
    KGGradientView *hero = [[KGGradientView alloc] initWithFrame:CGRectZero];
    hero.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *v = [[UIStackView alloc] initWithFrame:CGRectZero];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 4;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:hero.topAnchor constant:20],
        [v.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:20],
        [v.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-20],
        [v.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-20],
    ]];

    UILabel *t = KGLabel(@"SMSVideoBG 授权签发", 20, UIFontWeightBold, UIColor.whiteColor);
    [v addArrangedSubview:t];
    [v addArrangedSubview:KGLabel(@"客户报 UDID → 你签发 → 对方自动生效；删掉即掉授权",
                                  13, UIFontWeightMedium,
                                  [UIColor colorWithWhite:1.0 alpha:0.92])];
    _heroSub = KGLabel(@"", 12.5, UIFontWeightRegular, [UIColor colorWithWhite:1.0 alpha:0.85]);
    [v addArrangedSubview:_heroSub];
    return hero;
}

- (UIView *)issueCard {
    UIStackView *stack;
    UIView *card = KGCard(@"签发授权（把客户的 UDID 粘进来）", &stack);

    _udidField = KGField(@"设备 UDID（留空则读剪贴板）", 13, NO);
    [_udidField.heightAnchor constraintEqualToConstant:46].active = YES;
    _udidField.delegate = self;
    [stack addArrangedSubview:_udidField];

    _noteField = KGField(@"备注：客户名 / 微信号（可选）", 13, NO);
    [_noteField.heightAnchor constraintEqualToConstant:42].active = YES;
    _noteField.delegate = self;
    _noteField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    [stack addArrangedSubview:_noteField];

    _foreverSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _foreverSwitch.onTintColor = KGAccent();
    _foreverSwitch.on = YES;
    [_foreverSwitch addTarget:self action:@selector(foreverToggled:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:KGRow(@"永久有效", _foreverSwitch, nil)];

    _daysField = KGField(@"365", 16, YES);
    _daysField.text = @"365";
    _daysField.textAlignment = NSTextAlignmentRight;
    _daysField.delegate = self;
    [_daysField.widthAnchor constraintEqualToConstant:110].active = YES;
    [_daysField.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:KGRow(@"有效天数", _daysField, nil)];

    UIStackView *chips = [[UIStackView alloc] initWithFrame:CGRectZero];
    chips.axis = UILayoutConstraintAxisHorizontal;
    chips.distribution = UIStackViewDistributionFillEqually;
    chips.spacing = 8;
    for (NSNumber *d in @[@7, @30, @90, @365, @730]) {
        UIButton *b = KGButton([NSString stringWithFormat:@"%@天", d],
                               [UIColor tertiarySystemFillColor], [UIColor labelColor], 34);
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 10;
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chips addArrangedSubview:b];
    }
    [stack addArrangedSubview:chips];

    _issueBtn = KGButton(@"签发授权并推送", KGAccent(), UIColor.whiteColor, 48);
    _issueBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_issueBtn addTarget:self action:@selector(issueTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_issueBtn];

    _issueStatus = KGLabel(@"客户在控制App「授权」页点「本机 UDID」即可复制发给你。",
                           12.5, UIFontWeightMedium, [UIColor secondaryLabelColor]);
    [stack addArrangedSubview:_issueStatus];

    [self foreverToggled:nil];
    return card;
}

- (UIView *)listCard {
    UIStackView *stack;
    UIView *card = KGCard(@"授权名单（本机维护，删掉即撤销对方授权）", &stack);

    UIStackView *btns = [[UIStackView alloc] initWithFrame:CGRectZero];
    btns.axis = UILayoutConstraintAxisHorizontal;
    btns.distribution = UIStackViewDistributionFillEqually;
    btns.spacing = 8;

    UIButton *push = KGButton(@"立即推送名单", KGAccent(), UIColor.whiteColor, 42);
    [push addTarget:self action:@selector(pushTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *pull = KGButton(@"从远端拉取", [UIColor systemGrayColor], UIColor.whiteColor, 42);
    [pull addTarget:self action:@selector(pullTapped) forControlEvents:UIControlEventTouchUpInside];
    [btns addArrangedSubview:push];
    [btns addArrangedSubview:pull];
    [stack addArrangedSubview:btns];

    _listStatus = KGLabel(@"", 12.5, UIFontWeightMedium, [UIColor secondaryLabelColor]);
    [stack addArrangedSubview:_listStatus];

    _listStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _listStack.axis = UILayoutConstraintAxisVertical;
    _listStack.spacing = 8;
    [stack addArrangedSubview:_listStack];

    [stack addArrangedSubview:KGLabel(
        @"点某一行可以：复制 UDID / 改备注 / 改有效期 / 删除并撤销授权。"
        @"删除后对方设备最多 30 分钟掉授权（需联网；对方离线超过 30 天也会要求重新校验）。",
        12.5, UIFontWeightRegular, [UIColor tertiaryLabelColor])];
    return card;
}

- (UIView *)syncCard {
    UIStackView *stack;
    UIView *card = KGCard(@"GitHub 同步（名单存在你自己仓库里）", &stack);

    _tokenField = KGField(@"GitHub Token（repo 权限，只存本机）", 12.5, NO);
    _tokenField.text = [KGAuthClient token];
    _tokenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tokenField.delegate = self;
    [_tokenField.heightAnchor constraintEqualToConstant:42].active = YES;
    [stack addArrangedSubview:_tokenField];

    _repoField = KGField(@"仓库 owner/name", 12.5, NO);
    _repoField.text = [KGAuthClient repo];
    _repoField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _repoField.delegate = self;
    [_repoField.heightAnchor constraintEqualToConstant:42].active = YES;
    [stack addArrangedSubview:_repoField];

    _branchField = KGField(@"分支（默认 revoke）", 12.5, NO);
    _branchField.text = [KGAuthClient branch];
    _branchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _branchField.delegate = self;
    [_branchField.heightAnchor constraintEqualToConstant:42].active = YES;
    [stack addArrangedSubview:_branchField];

    UIButton *save = KGButton(@"保存设置", [UIColor tertiarySystemFillColor], [UIColor labelColor], 42);
    [save addTarget:self action:@selector(saveSyncSettings) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:save];

    _syncStatus = KGLabel(@"", 12.5, UIFontWeightMedium, [UIColor secondaryLabelColor]);
    [stack addArrangedSubview:_syncStatus];
    [self refreshSyncStatus];

    [stack addArrangedSubview:KGLabel(
        @"名单文件 auth.json 放在该分支下（插件读的就是它）。"
        @"仓库里只存 UDID 的 SHA256 指纹，不存 UDID 原文。",
        12.5, UIFontWeightRegular, [UIColor tertiaryLabelColor])];
    return card;
}

- (UIView *)giteeCard {
    UIStackView *stack;
    UIView *card = KGCard(@"Gitee 同步（国内直连 · 客户不用挂代理）", &stack);

    [stack addArrangedSubview:KGLabel(
        @"Gitee 是国内站点，客户手机直连就能拉到名单。建议和 GitHub 同时开，"
        @"两边名单内容完全一样（只有指纹，没有 UDID 原文）。",
        12.5, UIFontWeightRegular, [UIColor tertiaryLabelColor])];

    _giteeTokenField = KGField(@"Gitee 私人令牌（设置→私人令牌，勾 projects）", 12.5, NO);
    _giteeTokenField.text = [KGAuthClient giteeToken];
    _giteeTokenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _giteeTokenField.delegate = self;
    [_giteeTokenField.heightAnchor constraintEqualToConstant:42].active = YES;
    [stack addArrangedSubview:_giteeTokenField];

    _giteeRepoField = KGField(@"Gitee 仓库 owner/name（需公开）", 12.5, NO);
    _giteeRepoField.text = [KGAuthClient giteeRepo];
    _giteeRepoField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _giteeRepoField.delegate = self;
    [_giteeRepoField.heightAnchor constraintEqualToConstant:42].active = YES;
    [stack addArrangedSubview:_giteeRepoField];

    _giteeBranchField = KGField(@"分支（默认 master）", 12.5, NO);
    _giteeBranchField.text = [KGAuthClient giteeBranch];
    _giteeBranchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _giteeBranchField.delegate = self;
    [_giteeBranchField.heightAnchor constraintEqualToConstant:42].active = YES;
    [stack addArrangedSubview:_giteeBranchField];

    UIButton *save = KGButton(@"保存 Gitee 设置", [UIColor tertiarySystemFillColor], [UIColor labelColor], 42);
    [save addTarget:self action:@selector(saveGiteeSettings) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:save];

    _giteeStatus = KGLabel(@"", 12.5, UIFontWeightMedium, [UIColor secondaryLabelColor]);
    _giteeStatus.numberOfLines = 0;
    [stack addArrangedSubview:_giteeStatus];
    [self refreshGiteeStatus];
    return card;
}

- (void)refreshGiteeStatus {
    if (![KGAuthClient giteeConfigured]) {
        _giteeStatus.text = @"未启用（客户侧可先用「离线授权串」，或改用自定义源地址）";
        _giteeStatus.textColor = [UIColor secondaryLabelColor];
        return;
    }
    _giteeStatus.text = [NSString stringWithFormat:@"客户在控制 App 里长按「授权诊断」行填入：\n%@",
                         [KGAuthClient giteeRawURL] ?: @""];
    _giteeStatus.textColor = [UIColor systemGreenColor];
}

- (void)saveGiteeSettings {
    [self dismissKeyboard];
    [KGAuthClient setGiteeToken:_giteeTokenField.text];
    [KGAuthClient setGiteeRepo:_giteeRepoField.text];
    [KGAuthClient setGiteeBranch:_giteeBranchField.text];
    _giteeBranchField.text = [KGAuthClient giteeBranch];
    [self refreshGiteeStatus];
    if ([KGAuthClient giteeConfigured]) [self pushTapped];   // 顺手同步一次
}

- (UIView *)secretCard {
    UIStackView *stack;
    UIView *card = KGCard(@"签名密钥", &stack);

    NSString *secret = KGCompiledSecret();
    BOOL fallback = [secret hasPrefix:@"SVBG-LICENSE-FALLBACK"];
    UILabel *fp = KGLabel([NSString stringWithFormat:@"指纹 %@", KGSecretFingerprint(secret)],
                          14, UIFontWeightSemibold, fallback ? [UIColor systemOrangeColor] : [UIColor labelColor]);
    [stack addArrangedSubview:fp];

    [stack addArrangedSubview:KGLabel(
        fallback ? @"⚠️ 当前用的是内置兜底密钥：签名名单插件不认。请到 GitHub 仓库 "
                   @"Settings → Secrets 配置 SVB_LICENSE_SECRET（与插件编译用的同一个）。"
                 : @"与插件编译时注入的密钥一致（两边指纹相同 → 名单签名可被插件验证）。",
        12.5, UIFontWeightRegular,
        fallback ? [UIColor systemOrangeColor] : [UIColor tertiaryLabelColor])];
    return card;
}

- (UIView *)footerLabel {
    return KGLabel(@"SMSVideoBG v10 · 授权 = UDID 白名单（在线名单 + 离线授权串双通道）",
                   12, UIFontWeightRegular, [UIColor tertiaryLabelColor]);
}

#pragma mark 数据

- (NSMutableArray<NSDictionary *> *)devices {
    if (!_devices) {
        NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:KGPrefDevices];
        _devices = [NSMutableArray array];
        for (id d in a) if ([d isKindOfClass:[NSDictionary class]]) [_devices addObject:d];
    }
    return _devices;
}

- (void)saveDevices {
    [[NSUserDefaults standardUserDefaults] setObject:self.devices forKey:KGPrefDevices];
}

- (NSDictionary<NSString *, NSNumber *> *)localMap {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSDictionary *d in self.devices) {
        NSString *h = d[@"hash"];
        NSNumber *exp = d[@"exp"];
        if ([h isKindOfClass:[NSString class]] && h.length == 32 && [exp isKindOfClass:[NSNumber class]])
            m[[h uppercaseString]] = exp;
    }
    return m;
}

#pragma mark 刷新

- (void)refreshHero {
    _heroSub.text = [NSString stringWithFormat:@"本机名单 %lu 台 · 远端 %lu 台 · 上次同步 %@",
                     (unsigned long)self.devices.count,
                     (unsigned long)self.remoteMap.count,
                     KGShortDateTime(_lastSync)];
}

- (void)refreshSyncStatus {
    BOOL ok = [KGAuthClient configured];
    _syncStatus.text = ok ? [NSString stringWithFormat:@"已配置：%@ @ %@",
                             [KGAuthClient repo], [KGAuthClient branch]]
                          : @"尚未配置 Token —— 签发后无法推送，对方不会生效";
    _syncStatus.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
}

- (void)refreshList {
    while (_listStack.arrangedSubviews.count) {
        UIView *v = _listStack.arrangedSubviews.lastObject;
        [_listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (!self.devices.count) {
        [_listStack addArrangedSubview:KGLabel(@"还没有授权任何设备", 13, UIFontWeightRegular,
                                              [UIColor tertiaryLabelColor])];
    } else {
        // 新加的排在前面
        NSArray *sorted = [self.devices sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSTimeInterval ta = [a[@"addedAt"] doubleValue];
            NSTimeInterval tb = [b[@"addedAt"] doubleValue];
            if (ta == tb) return NSOrderedSame;
            return ta > tb ? NSOrderedAscending : NSOrderedDescending;
        }];
        for (NSInteger i = 0; i < (NSInteger)sorted.count; i++)
            [_listStack addArrangedSubview:[self rowForDevice:sorted[i]]];
    }
    [self refreshHero];

    NSInteger pushed = 0;
    for (NSDictionary *d in self.devices) {
        NSString *h = d[@"hash"];
        if ([h isKindOfClass:[NSString class]] && self.remoteMap[h]) pushed++;
    }
    _listStatus.text = [NSString stringWithFormat:@"共 %lu 台 · 远端已含 %ld 台",
                        (unsigned long)self.devices.count, (long)pushed];
    _listStatus.textColor = [UIColor secondaryLabelColor];
}

- (UIView *)rowForDevice:(NSDictionary *)d {
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
        [v.topAnchor constraintEqualToAnchor:row.topAnchor constant:9],
        [v.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [v.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [v.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-9],
    ]];

    NSString *udid = d[@"udid"] ?: @"(远端条目)";
    NSString *note = d[@"note"];
    NSString *hash = d[@"hash"] ?: @"";
    uint32_t exp = (uint32_t)[d[@"exp"] unsignedIntValue];

    UILabel *title = KGLabel(note.length ? note : KGAuthShortUDID(udid),
                             14.5, UIFontWeightSemibold, [UIColor labelColor]);
    NSInteger left = KGDaysLeftForExp(exp);
    NSString *leftText = (exp == KG_AUTH_FOREVER) ? @"永久"
        : (left < 0 ? [NSString stringWithFormat:@"已过期 %ld 天", (long)(-left)]
                    : [NSString stringWithFormat:@"剩 %ld 天", (long)left]);
    UIColor *leftColor = (exp == KG_AUTH_FOREVER) ? [UIColor systemGreenColor]
        : (left < 0 ? [UIColor systemRedColor]
                    : (left <= 30 ? [UIColor systemOrangeColor] : [UIColor systemGreenColor]));
    UILabel *badge = KGLabel(leftText, 12.5, UIFontWeightSemibold, leftColor);
    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *head = [[UIStackView alloc] initWithFrame:CGRectZero];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.spacing = 8;
    head.alignment = UIStackViewAlignmentCenter;
    [head addArrangedSubview:title];
    [head addArrangedSubview:[[UIView alloc] initWithFrame:CGRectZero]];
    [head addArrangedSubview:badge];
    [v addArrangedSubview:head];

    BOOL onRemote = (self.remoteMap[hash] != nil);
    NSString *line2 = [NSString stringWithFormat:@"%@ · %@%@",
        udid, KGDateTextForDayIndex(exp),
        onRemote ? @" · 远端已同步" : @" · 未推送"];
    UILabel *sub = KGLabel(line2, 12.5, UIFontWeightRegular,
                           onRemote ? [UIColor secondaryLabelColor] : [UIColor systemOrangeColor]);
    sub.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [v addArrangedSubview:sub];

    row.userInteractionEnabled = YES;
    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(rowTapped:)];
    [row addGestureRecognizer:t];
    objc_setAssociatedObject(row, "kg_hash", hash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return row;
}

- (NSInteger)indexForHash:(NSString *)hash {
    for (NSInteger i = 0; i < (NSInteger)self.devices.count; i++) {
        NSString *h = self.devices[i][@"hash"];
        if ([h isKindOfClass:[NSString class]] && [h caseInsensitiveCompare:hash] == NSOrderedSame) return i;
    }
    return -1;
}

#pragma mark 动作

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

- (void)issueTapped {
    [self dismissKeyboard];
    NSString *raw = [_udidField.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!raw.length) raw = [UIPasteboard generalPasteboard].string ?: @"";
    if (!KGAuthUDIDLooksValid(raw)) {
        _issueStatus.text = @"⚠️ UDID 不合法（去空格后至少 8 位，应为字母数字）";
        _issueStatus.textColor = [UIColor systemOrangeColor];
        return;
    }
    NSString *udid = KGAuthNormalizeUDID(raw);
    NSString *hash = KGAuthHashForUDID(udid);
    if (hash.length != 32) {
        _issueStatus.text = @"⚠️ UDID 计算失败";
        _issueStatus.textColor = [UIColor systemOrangeColor];
        return;
    }

    BOOL forever = _foreverSwitch.on;
    NSInteger days = forever ? 0 : [_daysField.text integerValue];
    if (!forever && days <= 0) days = 365;
    uint32_t exp = forever ? KG_AUTH_FOREVER : KGDayIndexFromNow(days);

    NSString *note = [_noteField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSInteger hit = [self indexForHash:hash];
    NSMutableDictionary *rec = [NSMutableDictionary dictionaryWithDictionary:
        @{@"udid": udid, @"hash": hash, @"exp": @(exp), @"addedAt": @([[NSDate date] timeIntervalSince1970])}];
    if (note.length) rec[@"note"] = note;
    else if (hit >= 0 && [self.devices[hit][@"note"] isKindOfClass:[NSString class]])
        rec[@"note"] = self.devices[hit][@"note"];

    if (hit >= 0) [self.devices replaceObjectAtIndex:hit withObject:rec];
    else [self.devices insertObject:rec atIndex:0];
    [self saveDevices];
    [self refreshList];

    _issueBtn.enabled = NO;
    _issueStatus.text = @"⏳ 正在推送名单…";
    _issueStatus.textColor = [UIColor secondaryLabelColor];
    __weak typeof(self) w = self;
    [self pushAllWithCompletion:^(BOOL ok, NSString *msg) {
        if (!w) return;
        w.issueBtn.enabled = YES;
        if (ok) {
            w.remoteMap = [w localMap];
            w.lastSync = [[NSDate date] timeIntervalSince1970];
            [w refreshList];
            [w refreshSyncStatus];
            [w refreshGiteeStatus];
            w.issueStatus.text = [NSString stringWithFormat:
                @"✓ %@ 已授权 · 至 %@ · 已同步（%@）· 对方 30 分钟内自动生效",
                KGAuthShortUDID(udid), KGDateTextForDayIndex(exp), msg ?: @""];
            w.issueStatus.textColor = [UIColor systemGreenColor];
            w.udidField.text = @"";
            w.noteField.text = @"";
        } else {
            w.issueStatus.text = [NSString stringWithFormat:
                @"⚠️ 已记入本机名单，但推送失败：%@（点「立即推送名单」可重试；"
                @"也可以长按名单行取「离线授权串」直接发给客户）", msg ?: @"未知错误"];
            w.issueStatus.textColor = [UIColor systemOrangeColor];
        }
    }];
}

- (void)rowTapped:(UITapGestureRecognizer *)g {
    NSString *hash = objc_getAssociatedObject(g.view, "kg_hash");
    NSInteger i = [self indexForHash:hash];
    if (i < 0) return;
    NSDictionary *d = self.devices[i];
    NSString *udid = d[@"udid"] ?: @"";
    NSString *note = d[@"note"];

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:(note.length ? note : KGAuthShortUDID(udid))
                         message:[NSString stringWithFormat:@"%@\n到期：%@",
                                  udid.length ? udid : @"(远端条目，本机没有 UDID 原文)",
                                  KGDateTextForDayIndex((uint32_t)[d[@"exp"] unsignedIntValue])]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"复制 UDID" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
        if (!udid.length) return;
        [UIPasteboard generalPasteboard].string = udid;
        w.issueStatus.text = @"✓ 已复制 UDID";
        w.issueStatus.textColor = [UIColor systemGreenColor];
    }]];
    // v2.1.0: 生成离线授权串 —— 客户完全连不上网时的兜底(不用任何网络就能授权)
    [ac addAction:[UIAlertAction actionWithTitle:@"生成离线授权串（发客户）"
                                           style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [w offlineTicket:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"改备注" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [w editNote:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"改有效期" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [w editExpiry:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除并撤销授权" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) { [w removeDevice:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

// v2.1.0: 生成离线授权串 —— 客户完全连不上网时, 这段文本就是"无需网络的授权"
- (void)offlineTicket:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.devices.count) return;
    NSDictionary *d = self.devices[i];
    NSString *udid = d[@"udid"] ?: @"";

    if (!udid.length) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"这条记录没有 UDID 原文"
                             message:@"离线授权串必须绑定设备 UDID；这条是从远端名单同步来的，"
                                     @"本机没存原文。让客户把 UDID 发来、重新签发一次即可。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    uint32_t exp = (uint32_t)[d[@"exp"] unsignedIntValue];
    NSString *ticket = KGAuthBuildOfflineTicket(KGCompiledSecret(), udid, exp);
    if (!ticket.length) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"生成失败" message:@"签名密钥异常，无法生成离线授权串。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    [UIPasteboard generalPasteboard].string = ticket;
    uint32_t cap = KGDayIndexFromNow(30);
    BOOL capped = (exp == KG_AUTH_FOREVER || exp > cap);

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"离线授权串已复制"
                         message:[NSString stringWithFormat:
        @"%@\n\n（全文已复制到剪贴板，直接粘给客户即可）\n\n"
        @"让客户在控制 App 里点「粘贴离线授权」导入：\n"
        @"· 不需要任何网络就能生效\n"
        @"· 只对这台设备有效（已绑定它的 UDID）\n"
        @"· 离线有效期最长 30 天%@\n"
        @"· 客户一旦联网校验成功，会自动转成完整期限：%@",
        KGAuthShortTicket(ticket),
        capped ? @"（本单按 30 天算）" : @"（按你签的期限算）",
        KGDateTextForDayIndex(exp)],
         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)editNote:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.devices.count) return;
    NSDictionary *d = self.devices[i];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"备注"
                                                               message:@"写个客户名/微信号，名单里一眼能对上"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = d[@"note"];
        tf.placeholder = @"例如 张三 / 微信 zs001";
    }];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
        NSString *t = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSMutableDictionary *m = [w.devices[i] mutableCopy];
        if (t.length) m[@"note"] = t; else [m removeObjectForKey:@"note"];
        [w.devices replaceObjectAtIndex:i withObject:m];
        [w saveDevices];
        [w refreshList];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)editExpiry:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.devices.count) return;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"改有效期"
                         message:@"留空 = 永久；改完会自动推送，对方 30 分钟内生效"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"天数（留空 = 永久）";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存并推送" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
        NSString *t = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        uint32_t exp = t.length == 0 ? KG_AUTH_FOREVER : KGDayIndexFromNow([t integerValue]);
        NSMutableDictionary *m = [w.devices[i] mutableCopy];
        m[@"exp"] = @(exp);
        [w.devices replaceObjectAtIndex:i withObject:m];
        [w saveDevices];
        [w refreshList];
        [w pushTapped];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)removeDevice:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.devices.count) return;
    NSDictionary *d = self.devices[i];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"撤销这台设备的授权？"
                         message:[NSString stringWithFormat:@"%@\n\n删除后名单里不再包含它，"
                                  @"对方设备最多 30 分钟掉授权（需联网）。",
                                  d[@"note"] ?: (d[@"udid"] ?: @"(远端条目)")]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除并推送" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) {
        [w.devices removeObjectAtIndex:i];
        [w saveDevices];
        [w refreshList];
        [w pushTapped];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)pushTapped {
    [self dismissKeyboard];
    _listStatus.text = @"⏳ 正在推送名单…";
    _listStatus.textColor = [UIColor secondaryLabelColor];
    __weak typeof(self) w = self;
    NSDictionary *map = [self localMap];
    [self pushAllWithCompletion:^(BOOL ok, NSString *msg) {
        if (!w) return;
        if (ok) {
            w.remoteMap = map;
            w.lastSync = [[NSDate date] timeIntervalSince1970];
            [w refreshList];
            [w refreshSyncStatus];
            [w refreshGiteeStatus];
            w.listStatus.text = [NSString stringWithFormat:
                @"✓ 已同步 %lu 台到 %@ · 对方 30 分钟内生效/掉授权",
                (unsigned long)map.count, msg ?: @"远端"];
            w.listStatus.textColor = [UIColor systemGreenColor];
        } else {
            w.listStatus.text = [NSString stringWithFormat:@"⚠️ 推送失败：%@", msg ?: @"未知错误"];
            w.listStatus.textColor = [UIColor systemOrangeColor];
        }
    }];
}

// v2.1.0: 把名单推到所有已配置的目标 (GitHub + Gitee), 全部成功才算成功
// 两个目标都配了就同时推, 插件端无论走哪条链路拿到的都是同一份名单。
- (void)pushAllWithCompletion:(void (^)(BOOL ok, NSString *msg))done {
    NSDictionary *map = [self localMap];
    NSString *secret = KGCompiledSecret();
    BOOL ghOn = [KGAuthClient configured];
    BOOL giteeOn = [KGAuthClient giteeConfigured];

    if (!ghOn && !giteeOn) {
        if (done) done(NO, @"还没配同步目标：至少填 GitHub Token，或 Gitee 令牌 + 仓库");
        return;
    }

    __block NSInteger pending = (ghOn ? 1 : 0) + (giteeOn ? 1 : 0);
    NSMutableArray *oks  = [NSMutableArray array];
    NSMutableArray *errs = [NSMutableArray array];
    __weak typeof(self) w = self;

    void (^finish)(void) = ^{
        pending--;
        if (pending > 0) return;
        typeof(self) s = w;
        if (!s) return;
        if (errs.count == 0) {
            if (done) done(YES, [oks componentsJoinedByString:@" + "]);
        } else {
            NSString *m = [errs componentsJoinedByString:@"；"];
            if (oks.count) m = [NSString stringWithFormat:@"%@（已成功：%@）", m,
                                [oks componentsJoinedByString:@" + "]];
            if (done) done(NO, m);
        }
    };

    if (ghOn) {
        [KGAuthClient pushDevices:map secret:secret completion:^(BOOL ok, NSString *err) {
            if (ok) [oks addObject:@"GitHub"];
            else [errs addObject:[NSString stringWithFormat:@"GitHub：%@", err ?: @"失败"]];
            finish();
        }];
    }
    if (giteeOn) {
        [KGAuthClient pushToGitee:map secret:secret completion:^(BOOL ok, NSString *err) {
            if (ok) [oks addObject:@"Gitee"];
            else [errs addObject:[NSString stringWithFormat:@"Gitee：%@", err ?: @"失败"]];
            finish();
        }];
    }
}

- (void)pullTapped {
    _listStatus.text = @"⏳ 正在拉取远端名单…";
    _listStatus.textColor = [UIColor secondaryLabelColor];
    __weak typeof(self) w = self;
    [KGAuthClient fetchAuthFile:^(NSInteger status, NSData *body, NSString *err) {
        if (!w) return;
        [w handlePullStatus:status body:body error:err verbose:YES];
    }];
}

- (void)pullRemoteQuietly {
    __weak typeof(self) w = self;
    [KGAuthClient fetchAuthFile:^(NSInteger status, NSData *body, NSString *err) {
        if (!w) return;
        [w handlePullStatus:status body:body error:err verbose:NO];
    }];
}

- (void)handlePullStatus:(NSInteger)status body:(NSData *)body error:(NSString *)err verbose:(BOOL)verbose {
    if (status == 404) {
        _remoteMap = @{};
        [self refreshList];
        if (verbose) {
            _listStatus.text = @"远端还没有名单文件（首次推送后就会生成）";
            _listStatus.textColor = [UIColor secondaryLabelColor];
        }
        return;
    }
    if (status != 200) {
        if (verbose) {
            _listStatus.text = [NSString stringWithFormat:@"⚠️ 拉取失败：%@", err ?: @"未知错误"];
            _listStatus.textColor = [UIColor systemOrangeColor];
        }
        return;
    }
    NSDictionary *map = KGAuthParseJSON(body, KGCompiledSecret());
    if (!map) {
        _listStatus.text = @"⚠️ 远端名单验签失败（密钥不一致或文件被改过）";
        _listStatus.textColor = [UIColor systemOrangeColor];
        return;
    }
    _remoteMap = map;
    _lastSync = [[NSDate date] timeIntervalSince1970];
    [self refreshList];
    _listStatus.text = [NSString stringWithFormat:@"✓ 远端名单 %lu 台（本机 %lu 台）",
                        (unsigned long)map.count, (unsigned long)self.devices.count];
    _listStatus.textColor = [UIColor systemGreenColor];
}

- (void)saveSyncSettings {
    [self dismissKeyboard];
    [KGAuthClient setToken:[_tokenField.text stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    [KGAuthClient setRepo:[_repoField.text stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    [KGAuthClient setBranch:[_branchField.text stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    _repoField.text = [KGAuthClient repo];
    _branchField.text = [KGAuthClient branch];
    [self refreshSyncStatus];
}

#pragma mark UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

#pragma mark - App Delegate

@implementation KGAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    KGViewController *vc = [[KGViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = KGCardColor();
        ap.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor labelColor]};
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
    }
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
