#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>
#import <string.h>
#import <math.h>
#import <unistd.h>

/*
 * Aevon App 侧（V0.2.1，AevonAppTakeoverV201；0.2.0 只读探针的标记保留收容）
 * ============================================================
 *
 * 为什么要有这个文件
 * ------------------
 * Aevon(86) 之后确认的结构性事实：backboardd 把同一根手指投两份 ——
 * 一份给 SpringBoard（`sendEvent:` / 识别器 / 视图命中都在这一份），
 * 一份直投前台 App 进程。我们在 SpringBoard 侧丢事件、停识别器、调带宽，
 * 动的全是第一份；App 那一份从来没被碰过。所以圆盘出来了、App 也跟着动，
 * 0.0.24 ~ 0.1.18 一直在碰不到目标的层上调参数。
 *
 * 这条路（路 B）的做法是把触摸判定搬进 App 进程，用 UIKit 官方机制：
 *   · 判向成功 → 让 App 收 touchesCancelled，手势中止；
 *   · 判向失败 → UIKit 自己补投 began + 全部累积 moved，只晚几帧。
 * 这正是 0.1.19 方案书里「暂存 60ms 再按序补投」想做的事，而且一行伪造事件都不用写。
 *
 * 0.2.0 只读探针的答案（Aevon(87) 日志验收）
 * ----------------------------------------------
 *   Q1 App 进程加载          → 真（com.apple.Preferences pid=56261）；
 *   Q2 读 com.Aevon 域配置    → 真（带宽=46 带高=60% 与默认值精确一致）；
 *   Q3 keyWindow 挂识别器     → 未验证（AppSideEnabled 开关默认关，安全闸按设计工作）；
 *   Q4 右缘落点坐标           → 未验证（识别器没挂）。
 * ③④ 被默认关的开关挡住，不是机制失败 → 0.2.1 直接做真接管，随真接管自证。
 *
 * 这一版（0.2.1，AevonAppTakeoverV201）才是真正的接管
 * ----------------------------------------------------
 * UIPanGestureRecognizer + 官方两个开关：
 *   · delaysTouchesBegan = YES  → 带内触摸的 began 先扣在 UIKit 手势环境里；
 *   · cancelsTouchesInView = YES → 判向成立时 App 收到的是**合法的 touchesCancelled**，
 *     不是伪造事件；判向失败时 UIKit 自动把 began + 全部累积 moved **按序补投**，
 *     点击 / 滚动 / 键盘只晚几帧，零伪造对象、零野指针 —— 这正是 0.1.19 方案书里
 *     「暂存 60ms 再按序补投」想做的事，由 UIKit 官方机制完成。
 *
 * 判向参数与 SpringBoard 侧成熟版完全一致：向左 30pt 且 |dx| ≥ |dy|×1.2。
 * 判向成立 → 取消 App 触摸 + Darwin 通知 com.aevon.rightedgetrigger 让 SB 呼圆盘。
 *
 * 三指急救（AevonAppPanicCrossV201，App 侧形态）：三根手指同时按下 → 识别器
 * 立刻 Failed（扣住的 began 全部补投），绝不持有任何触摸。App 沙盒写不了
 * com.Aevon 域，关开关的事仍由 SB 侧的急救负责；App 侧只保证**自己零持有**。
 *
 * 日志通道（App 沙盒写不了 /var/mobile，必须分层降级）
 * --------------------------------------------------
 *   ① 直接追加 /var/mobile/Aevon.log（越狱环境部分进程可写，只探测一次）
 *   ② 写**自己 bundleID 的偏好域**（沙盒 100% 允许；SpringBoard 是特权进程，
 *      能读任意域 —— 这是本版的主力通道）
 *   ③ 写 com.Aevon 域（部分设备允许）
 *   ④ NSLog 兜底
 * 通道②用「只写不读 + 序号递增」避免与 SpringBoard 侧抢写：
 * App 侧只写 `AevonAppProbe`（文本）+ `AevonAppProbeSeq`（序号），
 * 桥接侧只读不写，永远不会互相覆盖。
 */

static const char *AevonAppLogPath = "/var/mobile/Aevon.log";

/* CI 校验标记（本文件编进 AevonApp.dylib，不进主插件）。
 * V200 四条是 0.2.0 只读探针的历史标记，只加不能改（历史校验串纪律）。 */
__attribute__((used)) static const char AevonAppSideV200Marker[] = "AevonAppSideV200";
__attribute__((used)) static const char AevonAppObserveV200Marker[] = "AevonAppObserveV200";
__attribute__((used)) static const char AevonAppPrefDomainV200Marker[] = "AevonAppPrefDomainV200";
__attribute__((used)) static const char AevonAppWhitelistV200Marker[] = "AevonAppWhitelistV200";
/* V0.2.1 真接管标记 */
__attribute__((used)) static const char AevonAppTakeoverV201Marker[] = "AevonAppTakeoverV201";
__attribute__((used)) static const char AevonAppDirectionV201Marker[] = "AevonAppDirectionV201";
__attribute__((used)) static const char AevonAppNotifySBV201Marker[] = "AevonAppNotifySBV201";
__attribute__((used)) static const char AevonAppPanicCrossV201Marker[] = "AevonAppPanicCrossV201";

#pragma mark - 日志

static NSLock *gAevonAppLock = nil;
static NSMutableString *gAevonAppBuffer = nil;
static NSInteger gAevonAppLines = 0;
static NSInteger gAevonAppSeq = 0;      /* 通道②的序号，只增不减 */
static BOOL gAevonAppFileProbed = NO;
static BOOL gAevonAppFileWritable = NO;
static NSString *gAevonAppBundleID = @"?";
static NSString *gAevonAppChannel = @"未探测";

/* 每个进程最多写这么多行，防止某个 App 反复触发把偏好文件撑大 */
static const NSInteger AevonAppLineLimit = 400;
/* 通道②缓冲区上限（字符）。超出后丢最早的三分之一，保留最近的现场。 */
static const NSUInteger AevonAppBufferLimit = 8000;

static NSString *AevonAppTimestamp(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:[NSDate date]];
}

static BOOL AevonAppFileChannelProbe(void) {
    if (gAevonAppFileProbed) { return gAevonAppFileWritable; }
    gAevonAppFileProbed = YES;
    FILE *handle = fopen(AevonAppLogPath, "a");
    if (handle != NULL) {
        fclose(handle);
        gAevonAppFileWritable = YES;
        gAevonAppChannel = @"文件(/var/mobile/Aevon.log)";
    } else {
        gAevonAppFileWritable = NO;
        gAevonAppChannel = @"未定";
    }
    return gAevonAppFileWritable;
}

/* 通道②：写自己 bundleID 的域。沙盒一定允许（就是自己的偏好文件）。
 *
 * 语义是「全量 + 序号递增」而不是「增量 + 清空」：App 侧只写不读、从不删行，
 * SpringBoard 侧只读不写，因此两边不存在覆盖竞争；即使桥接侧漏读了几轮，
 * 下一轮拿到的仍是完整文本，只按「已输出行数」补新增部分。 */
static void AevonAppPublishToOwnDomainLocked(void) {
    if (gAevonAppBuffer.length == 0) { return; }
    CFStringRef domain = (__bridge CFStringRef)gAevonAppBundleID;
    if (domain == NULL) { return; }
    gAevonAppSeq += 1;
    /* 先取强引用快照再桥接：CFPreferencesSetAppValue 会 CFRetain，
     * 但直接桥接一个临时对象在 ARC 下生命周期靠不住，这一行省不得。 */
    NSString *snapshot = [NSString stringWithString:gAevonAppBuffer];
    CFPreferencesSetAppValue(CFSTR("AevonAppProbe"),
                             (__bridge CFStringRef)snapshot,
                             domain);
    CFPreferencesSetAppValue(CFSTR("AevonAppProbeSeq"),
                             (__bridge CFNumberRef)[NSNumber numberWithInteger:gAevonAppSeq],
                             domain);
    Boolean ok = CFPreferencesAppSynchronize(domain);
    if (ok) {
        gAevonAppChannel = @"偏好(自己域)";
    }
}

/* 通道③（写 com.Aevon 共享域）已删除：通道②在沙盒里一定可行，两个通道并存
 * 反而会产生「谁先清空缓冲」的竞争。日志只走一条路，读的人不必猜。 */

static void AevonAppLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (message == nil) { return; }

    /* NSLog 始终输出一份 —— Filza 看不到时还能用 Console 抓 */
    NSLog(@"[Aevon][App侧][%@] %@", gAevonAppBundleID, message);

    if (gAevonAppLines >= AevonAppLineLimit) { return; }
    gAevonAppLines += 1;

    NSString *line = [NSString stringWithFormat:@"[%@] [信息] [App侧(%@)] %@\r\n",
                      AevonAppTimestamp(), gAevonAppBundleID, message];
    const char *utf8 = line.UTF8String;
    if (utf8 == NULL) { return; }
    size_t length = strlen(utf8);

    [gAevonAppLock lock];

    if (!gAevonAppFileProbed) { AevonAppFileChannelProbe(); }

    /* 通道①：文件 */
    if (gAevonAppFileWritable) {
        FILE *handle = fopen(AevonAppLogPath, "a");
        if (handle != NULL) {
            fwrite(utf8, 1, length, handle);
            fclose(handle);
            [gAevonAppLock unlock];
            return;
        }
        /* 探测成功但真写失败 → 永久降级，避免反复触发沙盒拒绝 */
        gAevonAppFileWritable = NO;
        gAevonAppChannel = @"未定";
    }

    /* 通道②③：偏好中转 */
    if (gAevonAppBuffer.length + length > AevonAppBufferLimit) {
        NSUInteger cut = gAevonAppBuffer.length / 3;
        [gAevonAppBuffer deleteCharactersInRange:NSMakeRange(0, cut)];
    }
    [gAevonAppBuffer appendString:line];

    /* 关键行立刻发布，其余每 6 行一次，减少 cfprefsd IPC */
    BOOL important = ([message rangeOfString:@"配置"].location != NSNotFound ||
                      [message rangeOfString:@"挂载"].location != NSNotFound ||
                      [message rangeOfString:@"窗口"].location != NSNotFound ||
                      [message rangeOfString:@"加载"].location != NSNotFound ||
                      [message rangeOfString:@"通道"].location != NSNotFound ||
                      [message rangeOfString:@"异常"].location != NSNotFound);
    if (important || (gAevonAppLines % 6 == 0)) {
        AevonAppPublishToOwnDomainLocked();
    }

    [gAevonAppLock unlock];
}

#pragma mark - 配置读取

static BOOL AevonAppPrefBool(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        CFSTR("com.Aevon"));
    if (value == NULL) { return fallback; }
    BOOL result = fallback;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (type == CFNumberGetTypeID()) {
        int raw = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &raw);
        result = (raw != 0);
    }
    CFRelease(value);
    return result;
}

static double AevonAppPrefDouble(NSString *key, double fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        CFSTR("com.Aevon"));
    if (value == NULL) { return fallback; }
    double result = fallback;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result);
    } else if (type == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value doubleValue];
    }
    CFRelease(value);
    return result;
}

#pragma mark - 真接管识别器（V0.2.1）

/* Darwin 通知：判向成立 → 让 SpringBoard 呼圆盘（通知无载荷，SB 侧自己查开关）。
 * 这是 Myrtle/ScreenCore 验证过的跨进程通道，Axs 逆向也确认了通知是这类插件的
 * 标准回传方式；路 B 的回传方向是「App 判向 → SB 呼盘」。 */
static void AevonAppPostRightEdgeTrigger(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.rightedgetrigger"),
                                         NULL, NULL, true);
}

/*
 * 真接管识别器（AevonAppTakeoverV201）。
 *
 * UIPanGestureRecognizer + delegate 自持。与 0.2.0 只读探针的三个本质区别：
 *   ① delaysTouchesBegan = YES —— 带内触摸的 began 扣在 UIKit 手势环境里，
 *      App 在判向结束前拿不到任何东西（点击/滚动的位移不会先泄露给 App）；
 *   ② cancelsTouchesInView = YES —— 判向成立时 App 收到合法的 touchesCancelled；
 *   ③ 判向失败显式 state = Failed —— UIKit 把 began + 全部累积 moved 按序补投，
 *      只晚几帧，这正是「暂存 + 按序补投」的官方实现。
 *
 * 影响范围被 shouldReceiveTouch 压到最小：只接收右缘带内的落指，
 * 带外触摸一律 NO —— delaysTouchesBegan 对没被接收的触摸完全不生效。
 *
 * 带内轻点的代价（明说）：轻点会延迟到抬手才生效（识别器 Failed 之后补投）。
 * 这是「判向需要看见位移」的物理代价，46pt 带外的所有交互完全不受影响。
 */
@interface AevonAppTakeoverGesture : UIPanGestureRecognizer <UIGestureRecognizerDelegate>
@property (nonatomic, assign) double bandWidth;
@property (nonatomic, assign) double heightPercent;
@property (nonatomic, assign) CGSize screenSize;
@property (nonatomic, assign) CGPoint startPoint;   /* touchesBegan 时的起点 */
@property (nonatomic, assign) BOOL decided;         /* 本条触摸序列已判完（成/败） */
@property (nonatomic, assign) BOOL claimed;         /* 是否真的扣过 began（日志用） */
@end

@implementation AevonAppTakeoverGesture

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self != nil) {
        /* 两个开关就是路 B 的全部机制，写死在构造里，改这里的人必须知道代价 */
        self.delaysTouchesBegan = YES;
        self.cancelsTouchesInView = YES;
        self.delegate = self;
    }
    return self;
}

/* 只接收右缘带内的落指。开关每根手指都现读（恒假开关纪律：绝不缓存布尔）。 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldReceiveTouch:(UITouch *)touch {
    BOOL enabled = AevonAppPrefBool(@"AppSideEnabled", YES);
    BOOL edgeEnabled = AevonAppPrefBool(@"EdgeGestureEnabled", YES);
    if (!enabled || !edgeEnabled) { return NO; }

    UIWindow *window = touch.window;
    if (window == nil) { return NO; }
    CGSize screen = window.bounds.size;
    if (screen.width < 1.0 || screen.height < 1.0) { return NO; }

    CGPoint point = [touch locationInView:window];
    double gap = screen.width - point.x;
    double bandTop = screen.height * (1.0 - self.heightPercent / 100.0);
    BOOL inBand = (gap >= 0 && gap <= self.bandWidth && point.y >= bandTop);
    if (inBand) {
        self.screenSize = screen;
        return YES;
    }
    /* 带外：限频记一行自述（在带外 + 宽度差多少），然后绝不接收 */
    static CFAbsoluteTime lastRejectLog = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastRejectLog > 2.0) {
        lastRejectLog = now;
        if (gap < 0 || gap > self.bandWidth) {
            AevonAppLog(@"右缘带外：起手 (%.0f,%.0f) 距右缘 %.0fpt → 不接收（宽度差 %.0fpt 需 ≤%.0f）",
                        point.x, point.y, gap, gap - self.bandWidth, self.bandWidth);
        } else {
            AevonAppLog(@"右缘带外：起手 (%.0f,%.0f) 距右缘 %.0fpt → 不接收（y=%.0f 需 ≥%.0f，带高 %.0f%%）",
                        point.x, point.y, gap, point.y, bandTop, self.heightPercent);
        }
    }
    return NO;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.decided = NO;
    self.claimed = NO;

    /* 三指急救（App 侧形态，AevonAppPanicCrossV201）：三根手指同时按下 →
     * 立刻 Failed。Failed 会让 UIKit 把所有被扣住的 began 连同后续帧整段补投，
     * App 侧零持有；关开关（写 com.Aevon）是 SB 侧急救的职责，App 沙盒写不了。 */
    if (event != nil && event.allTouches.count >= 3) {
        AevonAppLog(@"急救（App 侧）：三指成形（%lu 指）→ 识别器立刻 Failed，全部触摸整段补投（AevonAppPanicCrossV201）",
                    (unsigned long)event.allTouches.count);
        self.state = UIGestureRecognizerStateFailed;
        return;
    }

    UITouch *touch = touches.anyObject;
    if (touch == nil || self.view == nil) { return; }
    self.startPoint = [touch locationInView:self.view];
    self.claimed = YES;
    double gap = self.screenSize.width - self.startPoint.x;
    AevonAppLog(@"右缘起手 (%.0f,%.0f) 距右缘 %.0fpt → 带内·began 已扣住（判向中，30pt 横向占优则接管）（AevonAppTakeoverV201）",
                self.startPoint.x, self.startPoint.y, gap);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (self.decided) { return; }
    UITouch *touch = touches.anyObject;
    if (touch == nil || self.view == nil) { return; }

    CGPoint now = [touch locationInView:self.view];
    double dx = now.x - self.startPoint.x;
    double dy = now.y - self.startPoint.y;

    /* 判向参数与 SpringBoard 侧成熟版一致：向左 30pt 且横向绝对占优 */
    if (dx <= -30.0 && fabs(dx) >= fabs(dy) * 1.2) {
        self.decided = YES;
        AevonAppLog(@"判向成立：dx=%.0f dy=%.0f → 取消 App 触摸（合法 touchesCancelled）+ 通知 SB 呼圆盘（AevonAppDirectionV201 AevonAppNotifySBV201）",
                    dx, dy);
        AevonAppPostRightEdgeTrigger();
        self.state = UIGestureRecognizerStateBegan;
        self.state = UIGestureRecognizerStateEnded;
        return;
    }
    /* 向右扫 → 放弃（那是在关闭/推回，不是呼出） */
    if (dx >= 8.0) {
        self.decided = YES;
        AevonAppLog(@"判向失败：dx=%.0f dy=%.0f → 向右扫，整段补投（AevonAppDirectionV201）", dx, dy);
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    /* 纵向占优 → 放弃（那是滚动，必须在 8pt 内让开，不能吃掉滚动起始） */
    if (fabs(dy) >= 8.0 && fabs(dy) > fabs(dx) * 1.2) {
        self.decided = YES;
        AevonAppLog(@"判向失败：dx=%.0f dy=%.0f → 纵向滚动，整段补投（AevonAppDirectionV201）", dx, dy);
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.decided || !self.claimed) { return; }
    UITouch *touch = touches.anyObject;
    CGPoint point = (touch != nil && self.view != nil) ? [touch locationInView:self.view] : CGPointZero;
    self.decided = YES;
    /* 没判出横向 30pt：轻点或短划。Failed → UIKit 把 began+moved+ended 整段补投，
     * 轻点在抬手时生效（带内轻点的已知代价），App 不会丢事件。 */
    AevonAppLog(@"抬手 (%.0f,%.0f)：未满 30pt 横向 → 整段补投（轻点延迟到抬手生效，App 不丢事件）",
                point.x, point.y);
    self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.decided = YES;
}

@end

#pragma mark - 主控制器

@interface AevonAppSide : NSObject
+ (instancetype)sharedInstance;
- (void)start;
@end

@implementation AevonAppSide {
    BOOL _installed;
    AevonAppTakeoverGesture *_gesture;
    double _bandWidth;
    double _heightPercent;
}

+ (instancetype)sharedInstance {
    static AevonAppSide *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AevonAppSide alloc] init];
    });
    return instance;
}

- (UIWindow *)currentKeyWindow {
    UIWindow *fallback = nil;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSSet<UIScene *> *scenes = app.connectedScenes;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isHidden) { continue; }
                if (window.isKeyWindow) { return window; }
                if (fallback == nil) { fallback = window; }
            }
        }
    } @catch (NSException *exception) {
        AevonAppLog(@"取 keyWindow 抛异常：%@", exception.reason ?: @"未知");
    }
    return fallback;
}

- (void)start {
    /* 双保险：filter 里本来就没有 SpringBoard，这里再挡一次，避免与主插件抢同一份日志 */
    NSArray<NSString *> *allowed = @[@"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (![allowed containsObject:gAevonAppBundleID]) {
        AevonAppLog(@"0.2.1 App 侧已加载，但不在验证白名单（%@）→ 本版不动作", allowed);
        return;
    }

    /* 先探测日志通道，否则下面第一条日志会把「通道」打成「未探测」 */
    if (gAevonAppLock != nil) {
        [gAevonAppLock lock];
        AevonAppFileChannelProbe();
        [gAevonAppLock unlock];
    }

    /* V0.2.1：默认开。0.2.0 的「默认关」是为了让安全闸先自证一轮；
     * Aevon(87) 证明注入/读域/日志通道全通后，真接管就是这个功能的本体。
     * 键从未被写过（日志确认「域里没有这个键」），改默认值不影响任何已写盘设备。 */
    BOOL enabled = AevonAppPrefBool(@"AppSideEnabled", YES);
    _bandWidth = AevonAppPrefDouble(@"RightEdgeWidth", 46.0);
    _heightPercent = AevonAppPrefDouble(@"RightEdgeHeight", 60.0);

    AevonAppLog(@"0.2.1 App 侧已加载：进程=%@ pid=%d 系统=%@ 通道=%@",
                gAevonAppBundleID, (int)getpid(),
                [UIDevice currentDevice].systemVersion ?: @"?",
                gAevonAppChannel);

    /* 配置读不到时这里会打印 fallback 值 —— 这一行就是 Q2 的答案：
     * 如果显示「域里没有键」，说明 App 沙盒读不到 com.Aevon，路 B 要换配置通道。 */
    CFPropertyListRef rawEnabled = CFPreferencesCopyAppValue(CFSTR("AppSideEnabled"), CFSTR("com.Aevon"));
    AevonAppLog(@"配置读取：AppSideEnabled=%@（原始值 %@）带宽=%.0f 带高=%.0f%%",
                enabled ? @"开" : @"关",
                rawEnabled ? @"有" : @"域里没有这个键",
                _bandWidth, _heightPercent);
    if (rawEnabled != NULL) { CFRelease(rawEnabled); }

    if (!enabled) {
        AevonAppLog(@"App 侧开关关着 → 只加载、不挂识别器（对 App 零影响）");
        return;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self_ = weakSelf;
        if (self_ == nil) { return; }
        [self_ installWithAttempt:1];
    });
}

- (void)handleBecomeActive {
    if (_installed) {
        /* 窗口可能换了（Safari 开新标签、设置进二级页），识别器跟着窗口走 */
        UIWindow *window = [self currentKeyWindow];
        if (window != nil && _gesture != nil && _gesture.view != window) {
            [window addGestureRecognizer:_gesture];
            AevonAppLog(@"识别器已改挂到新窗口 %@（尺寸 %.0fx%.0f）",
                        NSStringFromClass([window class]), window.bounds.size.width, window.bounds.size.height);
        }
        return;
    }
    [self installWithAttempt:1];
}

- (void)installWithAttempt:(NSInteger)attempt {
    if (_installed) { return; }

    UIWindow *window = [self currentKeyWindow];
    if (window == nil) {
        AevonAppLog(@"第 %ld 次取 keyWindow：没取到（已连接场景 %lu 个）",
                    (long)attempt,
                    (unsigned long)[[UIApplication sharedApplication] connectedScenes].count);
        if (attempt < 4) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * attempt * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self_ = weakSelf;
                if (self_ == nil) { return; }
                [self_ installWithAttempt:attempt + 1];
            });
        }
        return;
    }

    CGSize screen = window.bounds.size;
    if (screen.width < 1.0 || screen.height < 1.0) {
        AevonAppLog(@"窗口尺寸异常（%.0fx%.0f），放弃挂载", screen.width, screen.height);
        return;
    }

    _bandWidth = AevonAppPrefDouble(@"RightEdgeWidth", _bandWidth);
    _heightPercent = AevonAppPrefDouble(@"RightEdgeHeight", _heightPercent);

    if (_gesture == nil) {
        _gesture = [[AevonAppTakeoverGesture alloc] initWithTarget:nil action:nil];
    }
    _gesture.bandWidth = _bandWidth;
    _gesture.heightPercent = _heightPercent;
    _gesture.screenSize = screen;
    [window addGestureRecognizer:_gesture];

    _installed = YES;
    AevonAppLog(@"识别器已挂载：窗口=%@ 尺寸=%.0fx%.0f 带宽=%.0f 带高=%.0f%% 模式=真接管（delaysTouchesBegan=YES cancelsTouchesInView=YES，判向失败整段补投）（AevonAppTakeoverV201）",
                NSStringFromClass([window class]), screen.width, screen.height,
                _bandWidth, _heightPercent);
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void AevonAppSideEntry(void) {
    @autoreleasepool {
        @try {
            gAevonAppLock = [[NSLock alloc] init];
            gAevonAppBuffer = [[NSMutableString alloc] init];
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
            gAevonAppBundleID = [bundleID copy] ?: @"(无 bundleID)";

            /* SpringBoard 自己有一套（主插件），这里绝不能再开一份 */
            if ([gAevonAppBundleID isEqualToString:@"com.apple.springboard"]) { return; }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    [[AevonAppSide sharedInstance] start];
                } @catch (NSException *exception) {
                    AevonAppLog(@"启动抛异常：%@", exception.reason ?: @"未知");
                }
            });
        } @catch (NSException *exception) {
            NSLog(@"[Aevon][App侧] 构造阶段异常：%@", exception.reason ?: @"未知");
        }
    }
}
