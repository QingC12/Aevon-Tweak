#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>
#import <string.h>
#import <math.h>
#import <unistd.h>

/*
 * Aevon App 侧（V0.2.0，AevonAppSideV200 / AevonAppObserveV200）
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
 * 这一版（0.2.0）**不接管、不改时序**，只回答四个问题
 * ----------------------------------------------
 * 因为「动时序」出错时改的是所有 App 的手感，必须先证明基础设施成立：
 *   Q1 dylib 能不能在 App 进程里加载（而不是被系统拒掉）；
 *   Q2 App 侧能不能读到 `com.Aevon` 域的配置；
 *   Q3 能不能拿到 keyWindow 并把识别器挂上去；
 *   Q4 右缘的触摸到底会不会走进这个识别器，落点坐标是什么。
 * 四个问题任一为否，路 B 就地终止，不会进到改时序那一步。
 *
 * 零影响的实现方式（为什么这一版绝不会让 App 变卡 / 点不动）
 * --------------------------------------------------------
 * 不用 UIPanGestureRecognizer。用自定义 UIGestureRecognizer 子类，
 * 在整个触摸序列里**永远停在 possible**：不 success、不 fail、
 * `delaysTouchesBegan = NO`、`cancelsTouchesInView = NO`。
 * UIKit 的规则是「只有 recognized 才会 cancel 命中视图的触摸」，
 * 停在 possible 的识别器对手势竞争、响应链、highlighted 状态全部没有影响。
 * 它只做一件事：在 touchesBegan 里把落点记下来。
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

/* CI 校验标记（本文件编进 AevonApp.dylib，不进主插件） */
__attribute__((used)) static const char AevonAppSideV200Marker[] = "AevonAppSideV200";
__attribute__((used)) static const char AevonAppObserveV200Marker[] = "AevonAppObserveV200";
__attribute__((used)) static const char AevonAppPrefDomainV200Marker[] = "AevonAppPrefDomainV200";
__attribute__((used)) static const char AevonAppWhitelistV200Marker[] = "AevonAppWhitelistV200";

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

#pragma mark - 只读识别器

/*
 * 永远停在 possible 的识别器。
 *
 * 不设 `delaysTouchesBegan`（保持默认 NO）、不设 `cancelsTouchesInView`
 * （明确写成 NO），也从不给 self.state 赋值 —— 因此 UIKit 不会因它
 * cancel 任何触摸，App 的滚动手感、点击高亮、键盘全部不受影响。
 *
 * 0.2.1 才会在这里引入真正的判向与 delaysTouchesBegan。
 */
@interface AevonAppObserverGesture : UIGestureRecognizer
@property (nonatomic, assign) double bandWidth;
@property (nonatomic, assign) double heightPercent;
@property (nonatomic, assign) CGSize screenSize;
@property (nonatomic, assign) BOOL loggedMove;
@end

@implementation AevonAppObserverGesture

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.loggedMove = NO;
    UITouch *touch = touches.anyObject;
    if (touch == nil) { return; }
    CGPoint point = [touch locationInView:self.view];
    double gap = self.screenSize.width - point.x;
    double bandTop = self.screenSize.height * (1.0 - self.heightPercent / 100.0);
    BOOL inWidth = (gap >= 0 && gap <= self.bandWidth);
    BOOL inHeight = (point.y >= bandTop);

    NSString *verdict = nil;
    if (inWidth && inHeight) {
        verdict = @"带内（本版只记录，不接管）";
    } else if (!inWidth) {
        verdict = [NSString stringWithFormat:@"带外·宽度差 %.0fpt（带宽 %.0fpt）", gap - self.bandWidth, self.bandWidth];
    } else {
        verdict = [NSString stringWithFormat:@"带外·高度差（y=%.0f 需 ≥%.0f，带高 %.0f%%）",
                   point.y, bandTop, self.heightPercent];
    }
    AevonAppLog(@"右缘探针：起手 (%.0f,%.0f) 距右缘 %.0fpt → %@", point.x, point.y, gap, verdict);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (self.loggedMove) { return; }
    UITouch *touch = touches.anyObject;
    if (touch == nil) { return; }
    CGPoint previous = [touch previousLocationInView:self.view];
    CGPoint now = [touch locationInView:self.view];
    CGPoint delta = CGPointMake(now.x - previous.x, now.y - previous.y);
    if (fabs(delta.x) < 1.0 && fabs(delta.y) < 1.0) { return; }
    self.loggedMove = YES;
    AevonAppLog(@"右缘探针：首次移动 dx=%.0f dy=%.0f（本版不判向、不拦截）", delta.x, delta.y);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    UITouch *touch = touches.anyObject;
    if (touch == nil) { return; }
    CGPoint point = [touch locationInView:self.view];
    AevonAppLog(@"右缘探针：抬手于 (%.0f,%.0f)（本版未拦截任何触摸）", point.x, point.y);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
}

@end

#pragma mark - 主控制器

@interface AevonAppSide : NSObject
+ (instancetype)sharedInstance;
- (void)start;
@end

@implementation AevonAppSide {
    BOOL _installed;
    AevonAppObserverGesture *_gesture;
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
        AevonAppLog(@"0.2.0 App 侧已加载，但不在验证白名单（%@）→ 本版不动作", allowed);
        return;
    }

    /* 先探测日志通道，否则下面第一条日志会把「通道」打成「未探测」 */
    if (gAevonAppLock != nil) {
        [gAevonAppLock lock];
        AevonAppFileChannelProbe();
        [gAevonAppLock unlock];
    }

    BOOL enabled = AevonAppPrefBool(@"AppSideEnabled", NO);
    _bandWidth = AevonAppPrefDouble(@"RightEdgeWidth", 46.0);
    _heightPercent = AevonAppPrefDouble(@"RightEdgeHeight", 60.0);

    AevonAppLog(@"0.2.0 App 侧已加载：进程=%@ pid=%d 系统=%@ 通道=%@",
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
        _gesture = [[AevonAppObserverGesture alloc] initWithTarget:nil action:nil];
        /* 明确写死两个「不影响 App」的开关，将来改这里的人必须知道代价 */
        _gesture.delaysTouchesBegan = NO;
        _gesture.cancelsTouchesInView = NO;
    }
    _gesture.bandWidth = _bandWidth;
    _gesture.heightPercent = _heightPercent;
    _gesture.screenSize = screen;
    [window addGestureRecognizer:_gesture];

    _installed = YES;
    AevonAppLog(@"识别器已挂载：窗口=%@ 尺寸=%.0fx%.0f 带宽=%.0f 带高=%.0f%% 模式=只读探针（delaysTouchesBegan=NO cancelsTouchesInView=NO）",
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
