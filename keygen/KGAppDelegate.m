#import "KGAppDelegate.h"
#import "KGAuth.h"
#import <objc/runtime.h>

// ============================================================
// 板栗 v3.0.0 —— 统一授权签发 App (信息视频背景 + 备忘录视频背景通用; 客户侧不联网)
//   ① 客户在控制App「授权」页复制本机 UDID 发给你;
//   ② 你把 UDID 粘进来 (可加备注 / 选有效期) 点「生成授权串」;
//   ③ 授权串自动进剪贴板 -> 发给客户 -> 客户在控制 App 点「粘贴离线授权」导入即生效;
//   ④ 签发记录只留在你本机 (方便续期/查账), 不上传任何地方。
//
//   授权串里只有 UDID 的 SHA256 指纹 (32 位 HEX), 不含 UDID 原文。
//   注意: 授权串一旦发出, 到期前无法远程收回 —— 想控节奏就签短一点。
// ============================================================

static NSString * const KGPrefDevices = @"kg_devices";   // 本机签发记录 (UDID/备注/到期)

static UIColor *KGAccent(void)   { return [UIColor colorWithRed:0.98 green:0.27 blue:0.51 alpha:1.0]; }
static UIColor *KGAccent2(void)  { return [UIColor colorWithRed:0.63 green:0.32 blue:0.98 alpha:1.0]; }
static UIColor *KGCardColor(void) { return [UIColor secondarySystemGroupedBackgroundColor]; }

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

// v2.4.0: 产品位选择 (通用 / 仅信息 / 仅备忘录)
@property (nonatomic, strong) UISegmentedControl *productSeg;
@property (nonatomic, strong) UILabel *productHint;

@property (nonatomic, strong) UILabel *heroSub;
@property (nonatomic, strong) UIStackView *listStack;
@property (nonatomic, strong) UILabel *listStatus;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *devices;   // 本机签发记录

// v2.3.0: 只保留离线授权串 (不再有 GitHub / Gitee 名单同步)
- (void)offlineTicket:(NSInteger)i;
// v2.4.0: 当前选中的产品位 ("all" / "sms" / "memos")
- (NSString *)currentProduct;
@end

@implementation KGViewController

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"板栗";

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
    [root addArrangedSubview:[self secretCard]];
    [root addArrangedSubview:[self footerLabel]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [_scroll addGestureRecognizer:tap];

    [self refreshList];
    [self refreshHero];
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

    UILabel *t = KGLabel(@"板栗 · 授权签发", 20, UIFontWeightBold, UIColor.whiteColor);
    [v addArrangedSubview:t];
    [v addArrangedSubview:KGLabel(@"客户报 UDID → 你生成授权串 → 发给客户粘贴即生效",
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

    // v2.4.0 产品位: 信息版与备忘录版共用同一套密钥和指纹,
    // 靠这一段决定这个码给哪个插件用。
    [stack addArrangedSubview:KGLabel(@"这个码给谁用", 13, UIFontWeightSemibold,
                                      [UIColor secondaryLabelColor])];
    _productSeg = [[UISegmentedControl alloc] initWithItems:
                   @[@"通用", @"仅信息", @"仅备忘录"]];
    _productSeg.selectedSegmentIndex = 0;   // 默认签「通用」(两版都能导入)
    _productSeg.selectedSegmentTintColor = KGAccent();
    [_productSeg setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.whiteColor }
                               forState:UIControlStateSelected];
    [_productSeg addTarget:self action:@selector(productChanged:)
          forControlEvents:UIControlEventValueChanged];
    [_productSeg.heightAnchor constraintEqualToConstant:36].active = YES;
    [stack addArrangedSubview:_productSeg];

    _productHint = KGLabel(@"通用：信息版和备忘录版都能导入", 12,
                           UIFontWeightRegular, [UIColor tertiaryLabelColor]);
    [stack addArrangedSubview:_productHint];

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
    [stack addArrangedSubview:KGLabel(
        @"这个天数就是发给客户的授权串的有效期 —— 客户侧不再截断, 你签多久就是多久; 勾了「永久有效」就不过期。",
        12, UIFontWeightRegular, [UIColor tertiaryLabelColor])];

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

    _issueBtn = KGButton(@"生成授权串（并复制）", KGAccent(), UIColor.whiteColor, 48);
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
    UIView *card = KGCard(@"签发记录（只存在你本机）", &stack);

    _listStatus = KGLabel(@"", 12.5, UIFontWeightMedium, [UIColor secondaryLabelColor]);
    [stack addArrangedSubview:_listStatus];

    _listStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _listStack.axis = UILayoutConstraintAxisVertical;
    _listStack.spacing = 8;
    [stack addArrangedSubview:_listStack];

    [stack addArrangedSubview:KGLabel(
        @"点某一行可以：复制 UDID / 重新生成授权串 / 改备注 / 改有效期 / 删除记录。\n"
        @"注意：授权串一旦发给客户, 在到期前无法远程收回（客户侧不联网校验）—— 想控制节奏就签短一点。"
        @"记录只留在本机, 删掉记录不影响客户已导入的授权。",
        12.5, UIFontWeightRegular, [UIColor tertiaryLabelColor])];
    return card;
}

- (UIView *)secretCard {
    UIStackView *stack;
    UIView *card = KGCard(@"签名密钥", &stack);

    NSString *secret = KGCompiledSecret();
    BOOL fallback = [secret hasPrefix:@"VIDEOBG-LICENSE-FALLBACK"];
    UILabel *fp = KGLabel([NSString stringWithFormat:@"指纹 %@", KGSecretFingerprint(secret)],
                          14, UIFontWeightSemibold, fallback ? [UIColor systemOrangeColor] : [UIColor labelColor]);
    [stack addArrangedSubview:fp];

    [stack addArrangedSubview:KGLabel(
        fallback ? @"⚠️ 当前用的是内置兜底密钥：签出来的授权串插件不认。请到 GitHub 仓库 "
                   @"Settings → Secrets 配置 VIDEOBG_LICENSE_SECRET"
                   @"（两个插件仓库的这个 Secret 必须配同一个值，码才能两版通用）。"
                 : @"与插件编译时注入的密钥一致（两边指纹相同 → 你签发的授权串客户一定能导入）。",
        12.5, UIFontWeightRegular,
        fallback ? [UIColor systemOrangeColor] : [UIColor tertiaryLabelColor])];
    return card;
}

- (UIView *)footerLabel {
    return KGLabel(@"板栗 v3.0 · 客户侧不联网（不需要梯子），授权 = 你按 UDID 生成的一段授权串",
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

#pragma mark 刷新

- (void)refreshHero {
    _heroSub.text = [NSString stringWithFormat:@"本机签发记录 %lu 台 · 客户侧不联网, 只认你发的授权串",
                     (unsigned long)self.devices.count];
}

- (void)refreshList {
    while (_listStack.arrangedSubviews.count) {
        UIView *v = _listStack.arrangedSubviews.lastObject;
        [_listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (!self.devices.count) {
        [_listStack addArrangedSubview:KGLabel(@"还没有签发过任何设备", 13, UIFontWeightRegular,
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

    _listStatus.text = [NSString stringWithFormat:@"共 %lu 条签发记录（只在本机）",
                        (unsigned long)self.devices.count];
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

    NSString *udid = d[@"udid"] ?: @"(无 UDID 原文)";
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

    NSString *line2 = [NSString stringWithFormat:@"%@ · 有效期至 %@",
        udid, KGDateTextForDayIndex(exp)];
    UILabel *sub = KGLabel(line2, 12.5, UIFontWeightRegular, [UIColor secondaryLabelColor]);
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

// v2.4.0: 当前选中的产品位
- (NSString *)currentProduct {
    switch (_productSeg.selectedSegmentIndex) {
        case 1:  return KG_PRODUCT_SMS;
        case 2:  return KG_PRODUCT_MEMOS;
        default: return KG_PRODUCT_ALL;
    }
}

- (void)productChanged:(UISegmentedControl *)s {
    NSString *p = [self currentProduct];
    if ([p isEqualToString:KG_PRODUCT_SMS]) {
        _productHint.text = @"仅信息视频背景能用（备忘录版导入会提示产品位不对）";
    } else if ([p isEqualToString:KG_PRODUCT_MEMOS]) {
        _productHint.text = @"仅备忘录视频背景能用（信息版导入会提示产品位不对）";
    } else {
        _productHint.text = @"通用：信息版和备忘录版都能导入";
    }
}

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
    NSString *product = [self currentProduct];   // v2.4.0 产品位 (决定发给哪个插件用)
    NSMutableDictionary *rec = [NSMutableDictionary dictionaryWithDictionary:
        @{@"udid": udid, @"hash": hash, @"exp": @(exp), @"product": product,
          @"addedAt": @([[NSDate date] timeIntervalSince1970])}];
    if (note.length) rec[@"note"] = note;
    else if (hit >= 0 && [self.devices[hit][@"note"] isKindOfClass:[NSString class]])
        rec[@"note"] = self.devices[hit][@"note"];

    if (hit >= 0) [self.devices replaceObjectAtIndex:hit withObject:rec];
    else [self.devices insertObject:rec atIndex:0];
    [self saveDevices];
    [self refreshList];

    // v2.3.0: 签发 = 直接生成离线授权串 (不再推送任何远端名单)
    _issueStatus.text = [NSString stringWithFormat:@"✓ %@ 已签发 · 有效期至 %@ · 授权串已复制到剪贴板",
                         KGAuthShortUDID(udid), KGDateTextForDayIndex(exp)];
    _issueStatus.textColor = [UIColor systemGreenColor];
    _udidField.text = @"";
    _noteField.text = @"";
    [self offlineTicketForRecord:rec];
}

// 生成并复制授权串 (签发主流程 / 记录行里"重新生成" 共用)
- (void)offlineTicketForRecord:(NSDictionary *)rec {
    NSString *udid = rec[@"udid"] ?: @"";
    if (!udid.length) {
        [self kgAlert:@"这条记录没有 UDID 原文"
                  msg:@"离线授权串必须绑定设备 UDID。如果是从旧版本的远端名单同步进来的条目，"
                      @"本机没存原文 —— 让客户重新把 UDID 发来、再签发一次即可。"];
        return;
    }
    uint32_t exp = (uint32_t)[rec[@"exp"] unsignedIntValue];
    // v2.4.0: 产品位优先用记录里存的 (早期记录没这个字段 -> 按通用处理)
    NSString *product = [rec[@"product"] isKindOfClass:[NSString class]]
                      ? rec[@"product"] : KG_PRODUCT_ALL;
    NSString *ticket = KGAuthBuildOfflineTicket(KGCompiledSecret(), udid, exp, product);
    if (!ticket.length) {
        [self kgAlert:@"生成失败" msg:@"签名密钥异常，无法生成离线授权串。"];
        return;
    }
    [UIPasteboard generalPasteboard].string = ticket;

    NSString *msg = [NSString stringWithFormat:
        @"%@\n\n（全文已复制到剪贴板，直接粘给客户即可）\n\n"
        @"让客户在控制 App 里点「粘贴离线授权」导入：\n"
        @"- 不需要任何网络就能生效（客户端不联网，不需要梯子）\n"
        @"- 只对这台设备有效（已绑定它的 UDID）\n"
        @"- 适用范围：%@\n"
        @"- 有效期到 %@\n\n"
        @"注意：授权串一旦发出，到期前无法远程收回；想控制节奏就签短一点（如 30 天），到期让他来找你换新的。",
        KGAuthShortTicket(ticket),
        KGProductText(product),
        (exp == KG_AUTH_FOREVER) ? @"永久" : KGDateTextForDayIndex(exp)];
    [self kgAlert:@"离线授权串已复制" msg:msg];
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
                                  udid.length ? udid : @"(没有 UDID 原文)",
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
    // v2.3.0: 重新生成一份授权串 (改了天数之后用这个)
    [ac addAction:[UIAlertAction actionWithTitle:@"重新生成授权串（发客户）"
                                           style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [w offlineTicket:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"改备注" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [w editNote:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"改有效期" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [w editExpiry:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除记录" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) { [w removeDevice:i]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

// v2.3.0: 生成离线授权串 (记录行 -> 重新生成一份新的发客户)
- (void)offlineTicket:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.devices.count) return;
    [self offlineTicketForRecord:self.devices[i]];
}

- (void)kgAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
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
                         message:@"留空 = 永久。改完会自动生成一份新的授权串（已复制），"
                                 @"发给客户重新导入即可生效 —— 客户侧不联网，旧的那份要等到期才失效。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"天数（留空 = 永久）";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存并生成新授权串" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
        NSString *t = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        uint32_t exp = t.length == 0 ? KG_AUTH_FOREVER : KGDayIndexFromNow([t integerValue]);
        NSMutableDictionary *m = [w.devices[i] mutableCopy];
        m[@"exp"] = @(exp);
        [w.devices replaceObjectAtIndex:i withObject:m];
        [w saveDevices];
        [w refreshList];
        [w offlineTicketForRecord:m];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)removeDevice:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.devices.count) return;
    NSDictionary *d = self.devices[i];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"删掉这条签发记录？"
                         message:[NSString stringWithFormat:@"%@\n\n"
                                  @"只从本机记录里删掉 —— 客户已经导入的授权串不受影响（到期自动失效）。"
                                  @"客户侧不联网，没法远程收回。",
                                  d[@"note"] ?: (d[@"udid"] ?: @"(无 UDID 原文)")]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除记录" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) {
        [w.devices removeObjectAtIndex:i];
        [w saveDevices];
        [w refreshList];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
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
