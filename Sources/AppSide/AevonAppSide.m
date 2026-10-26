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
 * 判向参数（V0.2.2 提前，AevonAppEarlyJudgeV202）
 * ------------------------------------------------
 * Aevon(88) 日志根因：7 根「带内·began 已扣住」的横向呼盘手指**全部在 App 侧
 * 序列断裂**（无 moved 判定、无抬手、无任何下文），唯一幸存的一根是纵向
 * （dy=-84，8pt 纵向失败判据先触发，主动 Failed → 补投正常）。
 * 结论：30pt 判向太慢 —— App 内滚动容器（UITableView 等）的 pan 识别器约
 * 10pt（不分方向）就 Began 抢先赢得竞争，我们被打成 Failed 并收到
 * touchesCancelled（当时这一分支静默无日志，断裂真相由 0.2.2 取证补上）。
 *
 * 修复 = 判向成功阈值 30pt → 8pt（横向占优 |dx|≥|dy|×1.2 不变），在滚动 pan
 * 之前赢。SB 侧 0.1.9 有同款 8pt 判向先例。纵向失败（8pt 占优）与向右失败
 * （8pt）不变；touchesCancelled 补取证日志，若 8pt 后仍有断裂，下版对症。
 *
 * V0.2.5 权威判向 + 两帧确认（Aevon(91) 判读，AevonAppWinAuthV205 /
 * AevonAppTwoFrameV205）
 * ------------------------------------------------
 * Aevon(91)：链路（扣住→判向成立→呼盘 13 次）全程在跑，用户仍报「App 跟着动」。
 * 两个新认识：①「我们先 Began」≠「滚动 pan 没动」—— 滚动 pan 阈值（~10pt）与
 * 我们同帧且挂得更深，取消落地前页面已开始动；②首帧判向有误触发反例 ——
 * 20:31:13 用户纵向滚动（总位移 dy=-102），首帧 dx≈-11 被误判为左滑，圆盘在
 * 滚动中弹出。修复 = ①失败要求（failure requirement）：带内平移/轻扫识别器
 * 必须等我们 Failed 才允许 Began —— 我们成功则 App 物理上无法滚动；
 * ②成功判向改两帧确认（|dx|≥14 快划豁免 + 抬手快判兜底）。
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
/* V0.2.2 判向提前标记（Aevon(88) 日志根因） */
__attribute__((used)) static const char AevonAppEarlyJudgeV202Marker[] = "AevonAppEarlyJudgeV202";
/* V0.2.3 让路通道 + 卡死自愈（Aevon(89) 日志根因） */
__attribute__((used)) static const char AevonAppStuckGuardV203Marker[] = "AevonAppStuckGuardV203";
__attribute__((used)) static const char AevonAppYieldNotifyV203Marker[] = "AevonAppYieldNotifyV203";
/* V0.2.4 全 App 白名单 + 排除表 */
__attribute__((used)) static const char AevonAppAllAppsV204Marker[] = "AevonAppAllAppsV204";
__attribute__((used)) static const char AevonAppExcludeV204Marker[] = "AevonAppExcludeV204";
/* V0.2.5 权威判向 + 两帧确认（Aevon(91) 判读：用户报「问题依旧」） */
__attribute__((used)) static const char AevonAppWinAuthV205Marker[] = "AevonAppWinAuthV205";
__attribute__((used)) static const char AevonAppTwoFrameV205Marker[] = "AevonAppTwoFrameV205";
/* V0.2.6 判向失败回传（Aevon(92) 判读：兜底呼盘不知道 App 已判失败） */
__attribute__((used)) static const char AevonAppFailNotifyV206Marker[] = "AevonAppFailNotifyV206";
/* V0.2.7 挂载重试加宽（Aevon(93)：QQ 冷启动 ~3s 才有 keyWindow，旧 4 次重试撑不过） */
__attribute__((used)) static const char AevonAppMountRetryV207Marker[] = "AevonAppMountRetryV207";
/* V0.2.10 盲期（Aevon(96) 抖音第 8 次：App 侧未挂载时 SB 照旧呼盘 → App 跟着滚） */
__attribute__((used)) static const char AevonAppReadyV210Marker[] = "AevonAppReadyV210";
__attribute__((used)) static const char AevonAppMountFastV210Marker[] = "AevonAppMountFastV210";

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

/* V0.2.9（AevonFloatStandDownV209）：读字符串（当前浮窗里装的是哪个 App）。
 * 沙盒里读 com.Aevon 域这条路 AppSideEnabled / 带宽已经走了好几版（真机验证过），
 * 读不到就是空串 —— 等价「没有浮窗」，识别器按常态工作。 */
static NSString *AevonAppPrefString(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        CFSTR("com.Aevon"));
    if (value == NULL) { return @""; }
    NSString *result = @"";
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [NSString stringWithString:(__bridge NSString *)value];
    }
    CFRelease(value);
    return result;
}

/* 本进程是否正被装在浮窗里。
 *
 * Aevon(95) 主诉「悬浮内的 APP 无法滑动，只能点击」的结构性来源：
 * 浮窗里跑的是真实 App 场景，但它被缩到 289x626 摆在屏幕上某处 ——
 * 此时「屏幕右缘 46pt」根本不代表用户想呼盘，只代表他手指落在浮窗右侧。
 * 我们却照旧扣住 began（delaysTouchesBegan）判向，斜向滑动又判不出结果，
 * 于是 App 直到抬手都拿不到事件 → 页面纹丝不动，只有点击（抬手时补投）还活。
 * 判据由 SpringBoard 写进偏好域（开窗写 bundleID、关窗删键），这里只读。 */
static BOOL AevonAppInFloatingWindow(void) {
    NSString *bundle = AevonAppPrefString(@"AevonFloatBundle");
    if (bundle.length == 0) { return NO; }
    NSString *mine = [[NSBundle mainBundle] bundleIdentifier];
    if (mine.length == 0) { mine = gAevonAppBundleID; }
    if (mine.length == 0) { return NO; }
    return [bundle isEqualToString:mine];
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

/* V0.2.3（AevonAppYieldNotifyV203）：带内 began 即刻广播「App 侧已扣住本指」。
 *
 * Aevon(89) 实证：SB 全局热区通道与 App 侧识别器在同一根手指上竞速，
 * 4 根「began 已扣住」的手指在 App 进程内整段断流（无 moved / 无取消 / 无抬手），
 * 且全部发生在 SB 热区同时接管时。让路通知让 SB 在收到后立刻停吞本指
 * （保留观察与兜底触发）—— 如果 SB 吞是死因，序列被救活；如果不是，行为不变。
 * 非注入 App 不发本通知，SB 行为完全不变。 */
static void AevonAppPostRightEdgeBegan(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.rightedgebegan"),
                                         NULL, NULL, true);
}

/* V0.2.6（AevonAppFailNotifyV206）：判向失败回传。
 *
 * Aevon(92) 判读：16 次「让路」里 8 次最终由 global 兜底呼盘 —— App 侧判向失败
 * （纵向/向右）时 SB 不知道，兜底只看 dx=-30 就呼盘，App 那份照滚 =
 * 用户看到的「呼出圆盘的同时全屏 App 也被操作」。现在失败也广播，
 * SB 在 1.5s 内不再允许 global 兜底呼盘（成功路径的 rightedgetrigger 不受影响）。 */
static void AevonAppPostRightEdgeFail(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.rightedgefail"),
                                         NULL, NULL, true);
}

/* V0.2.10（AevonAppReadyV210）：「App 侧已就位」广播。
 *
 * Aevon(96) 09:49:09 铁证（抖音冷启动，落点 418,777 距右缘 11pt）：
 *   `[右缘] 起手 … 归口=右缘接管带·在带内·按下即接管（第 8 次）`
 *   → `[右缘] 判向成立 → 呼出圆盘`
 *   → `[右缘] 诊断：前台 App=com.ss.iphone.ugc.Aweme，本指无 App 侧起手痕迹（>2s 无让路）`
 * 也就是说：那一秒里 App 侧识别器**还没挂上**，App 手里那份触摸从头到尾没被取消，
 * 圆盘一滑动，抖音就跟着滚 —— 这就是「偶尔还是会触发」的全部来源。
 *
 * SB 侧没有办法事后夺走 App 已经拿到的触摸（backboardd 双投，sendEvent 只影响 SB 那份），
 * 所以唯一诚实的修法是：**呼盘之前先确认 App 侧在不在**。挂载成功即刻、以及每次前台
 * 激活都广播一次本通知，SB 收到就把当前前台 App 记为「在场」；不在场时宁可这次不呼盘，
 * 也绝不出现「圆盘出来了 + App 也在动」的双响应。 */
static void AevonAppPostReady(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.appready"),
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
@property (nonatomic, assign) BOOL sawMoved;        /* 是否收到过首帧移动（V0.2.3 取证） */
@property (nonatomic, assign) int moveFrames;       /* 收到过几帧移动（V0.2.5 两帧确认） */
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

    /* V0.2.9（AevonFloatStandDownV209）：装进浮窗时整体退让。
     * 浮窗的「右边缘」不是屏幕右边缘，用户在那里滑是在滚内容，不是呼盘。
     * 退让 = 一根手指都不接收 → delaysTouchesBegan / cancelsTouchesInView 全部不生效，
     * 滑动与点击原样归 App。 */
    if (AevonAppInFloatingWindow()) {
        static CFAbsoluteTime lastFloatLog = 0;
        CFAbsoluteTime nowFloat = CFAbsoluteTimeGetCurrent();
        if (nowFloat - lastFloatLog > 3.0) {
            lastFloatLog = nowFloat;
            AevonAppLog(@"浮窗模式：本 App 正装在浮窗里 → 右缘判向整体退让（不扣 began、不建失败要求，滑动/点击全归自己）（AevonFloatStandDownV209）");
        }
        return NO;
    }

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

/* V0.2.5 权威判向（AevonAppWinAuthV205）—— 路线 B 的最后一道闸。
 *
 * Aevon(91) 判读：链路（扣住→判向成立→呼盘）已全程在跑，但用户仍报「App 跟着动」。
 * 原因：「我们先 Began」不等于「滚动 pan 没动」—— 滚动容器（UITableView 等）的 pan
 * 起步阈值（约 10pt）与我们在同一帧达到，而它挂在更深的视图上、每帧先处理；
 * 我们 cancel 落地前页面已经开始动，部分场景它 Began 后还会继续跟完。
 *
 * 修复 = UIKit 官方的「失败要求」机制：对本识别器的委托实现
 * gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer:，对带内的平移/轻扫
 * 识别器返回 YES —— 含义是「它们必须等我们 Failed 才允许 Began」：
 *   · 我们成功（横向呼盘）→ 我们永不 Failed → 它们物理上无法开始 → App 无法滚动；
 *   · 我们失败（纵向/轻点/抬手）→ 它们照常开始，只晚我们判定的那一两帧。
 * 只压带内（±6pt 容差）且只在开关打开时设置 —— 带外一切交互原样。 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (self.view == nil) { return NO; }
    /* 开关每帧现读（恒假开关纪律）：关了绝不设失败要求，App 手感原样 */
    if (!AevonAppPrefBool(@"AppSideEnabled", YES) ||
        !AevonAppPrefBool(@"EdgeGestureEnabled", YES)) { return NO; }
    /* V0.2.9（AevonFloatStandDownV209）：浮窗里绝不建失败要求 ——
     * 建了就等于「滚动 pan 必须等我们判完才能开始」，而浮窗里我们不想判。 */
    if (AevonAppInFloatingWindow()) { return NO; }
    /* 只压平移/轻扫类；点按/长按不压（按钮、键盘、菜单不受影响） */
    if (![otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] &&
        ![otherGestureRecognizer isKindOfClass:[UISwipeGestureRecognizer class]]) { return NO; }
    /* 只压带内（+6pt 容差）的识别器 —— 用对方识别器的当前落点判定 */
    CGPoint point = [otherGestureRecognizer locationInView:self.view];
    CGSize screen = self.screenSize;
    if (screen.width < 1.0 || screen.height < 1.0) { return NO; }
    double gap = screen.width - point.x;
    double bandTop = screen.height * (1.0 - self.heightPercent / 100.0);
    BOOL inBand = (gap >= -6.0 && gap <= self.bandWidth + 6.0 && point.y >= bandTop - 6.0);
    if (!inBand) { return NO; }
    static BOOL loggedOnce = NO;
    if (!loggedOnce) {
        loggedOnce = YES;
        AevonAppLog(@"失败要求已建立：带内平移/轻扫识别器必须等本识别器判完才开始（判向成立=App 无法滚动；判向失败=照常，只晚一两帧）（AevonAppWinAuthV205）");
    }
    return YES;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.decided = NO;
    self.claimed = NO;
    self.sawMoved = NO;
    self.moveFrames = 0;

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
    AevonAppLog(@"右缘起手 (%.0f,%.0f) 距右缘 %.0fpt → 带内·began 已扣住（判向中，8pt 横向占优则接管）（AevonAppTakeoverV201）",
                self.startPoint.x, self.startPoint.y, gap);
    /* V0.2.3（AevonAppYieldNotifyV203）：即刻通知 SB「本指已被 App 侧扣住」→
     * SB 全局通道停吞让路（保留兜底触发）。若 Aevon(89) 的序列断流真凶是
     * SB 侧吞，这一步在首帧 moved（约 30ms 后）之前就把它解除了。 */
    AevonAppPostRightEdgeBegan();
    /* V0.2.3（AevonAppStuckGuardV203）卡死自愈：Aevon(89) 里 4 根手指 began 扣住后
     * 连 moved / cancelled / ended 全都没有（序列疑似在系统层被断流）。
     * 未判定就主动 Failed —— 手势不再持有任何东西，App 侧零残留；
     * 若序列其实活着（用户慢启动），Failed 会整段补投，轻点 / 长按只晚这一小段。
     * V0.2.9（AevonAppAnyMoveFailV209）：1.5s → **0.8s**。扣住的代价是「这段时间
     * App 收不到任何事件」，用户感知成「页面不动」；0.8s 仍留足真机判向时间
     * （正常判定在 1~2 帧 ≈ 30ms 内完成），同时把最坏情况的手感损失砍掉近一半。 */
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.decided || !strongSelf.claimed) { return; }
        strongSelf.decided = YES;
        AevonAppLog(@"卡死自愈：began 扣住 0.8s 未判定（无移动帧也无取消，序列疑似在系统层中断）→ 主动 Failed 整段放行（AevonAppStuckGuardV203 AevonAppAnyMoveFailV209）");
        AevonAppPostRightEdgeFail();
        strongSelf.state = UIGestureRecognizerStateFailed;
    });
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (self.decided) { return; }
    UITouch *touch = touches.anyObject;
    if (touch == nil || self.view == nil) { return; }

    CGPoint now = [touch locationInView:self.view];
    double dx = now.x - self.startPoint.x;
    double dy = now.y - self.startPoint.y;

    /* V0.2.3 取证（Aevon(89) 根因排查）：Aevon(89) 里 4 根手指 began 之后连 moved
     * 都没到过 —— 但「没日志」既可能是「没收到」也可能是「收到没写」。
     * 首帧移动无条件记一行：下版日志若「有起手、无首帧移动」，就是投递层断流；
     * 若「有首帧移动、无判定」，才是判向/日志层的问题。每条序列只记一次。 */
    if (!self.sawMoved) {
        self.sawMoved = YES;
        AevonAppLog(@"首帧移动：dx=%.1f dy=%.1f（序列仍在投递，判向进行中）", dx, dy);
    }
    self.moveFrames += 1;

    /* 判向（V0.2.2 提前到 8pt，AevonAppEarlyJudgeV202）：
     * 30pt 太慢 —— Aevon(88) 证明 App 内滚动容器的 pan 约 10pt 就 Began 抢先，
     * 我们还没判就被打成 Failed。横向占优 |dx|≥|dy|×1.2 的几何不变。 */
    BOOL horizontal = (dx <= -8.0 && fabs(dx) >= fabs(dy) * 1.2);

    /* V0.2.5 两帧确认（AevonAppTwoFrameV205）防误触：Aevon(91) 20:31:13 用户在
     * 纵向滚动（总位移 dy=-102），首帧恰好 dx≈-11 dy≈3 横向占优 → 圆盘在滚动中
     * 弹出打断操作。第一帧不再直接宣布成功：
     *   · |dx|≥14 的大力横向首帧仍立即成立（快划不牺牲响应）；
     *   · 否则等第二帧，确认**总位移**仍横向占优才成立；随后变纵向会走下面的失败分支。
     * 有了失败要求（AevonAppWinAuthV205）滚动 pan 本来就在等我们，多这一帧无代价。 */
    if (horizontal && (self.moveFrames >= 2 || dx <= -14.0)) {
        self.decided = YES;
        AevonAppLog(@"判向成立：dx=%.0f dy=%.0f（第 %d 帧确认）→ 取消 App 触摸（合法 touchesCancelled）+ 通知 SB 呼圆盘（AevonAppDirectionV201 AevonAppNotifySBV201 AevonAppEarlyJudgeV202 AevonAppTwoFrameV205）",
                    dx, dy, self.moveFrames);
        AevonAppPostRightEdgeTrigger();
        self.state = UIGestureRecognizerStateBegan;
        self.state = UIGestureRecognizerStateEnded;
        return;
    }
    /* 向右扫 → 放弃（那是在关闭/推回，不是呼出） */
    if (dx >= 8.0) {
        self.decided = YES;
        AevonAppLog(@"判向失败：dx=%.0f dy=%.0f → 向右扫，整段补投（AevonAppDirectionV201 AevonAppFailNotifyV206）", dx, dy);
        AevonAppPostRightEdgeFail();
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    /* 纵向占优 → 放弃（那是滚动，必须在 8pt 内让开，不能吃掉滚动起始） */
    if (fabs(dy) >= 8.0 && fabs(dy) > fabs(dx) * 1.2) {
        self.decided = YES;
        AevonAppLog(@"判向失败：dx=%.0f dy=%.0f → 纵向滚动，整段补投（AevonAppDirectionV201 AevonAppFailNotifyV206）", dx, dy);
        AevonAppPostRightEdgeFail();
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    /* V0.2.9（AevonAppAnyMoveFailV209）：**任何方向走过 10pt 仍未判成立 → 立刻失败放行**。
     *
     * Aevon(95) 主诉「只能点击、不能滑动」的最后一环就在这里：
     * 斜向滑动（例如 dx=-12 dy=-10）既不满足「横向 ≥ 纵向×1.2」（判成立），
     * 也不满足「纵向 > 横向×1.2」（判失败）—— 于是**一直不判定**。
     * began 被 delaysTouchesBegan 扣在 UIKit 手势环境里，App 直到抬手
     * （或 0.8 秒自愈）之前什么事件都收不到，表现就是「页面纹丝不动，只能点」。
     * 现在只要总位移 ≥10pt 且没判成横向，一律失败 —— 失败会立刻把 began +
     * 全部累积 moved 按序补投，App 只晚一两帧，滚动完整跟手。 */
    if (fabs(dx) >= 10.0 || fabs(dy) >= 10.0) {
        self.decided = YES;
        AevonAppLog(@"判向失败：dx=%.0f dy=%.0f → 斜向/方向未定但已过 10pt，立刻整段补投（AevonAppAnyMoveFailV209 AevonAppFailNotifyV206）", dx, dy);
        AevonAppPostRightEdgeFail();
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.decided || !self.claimed) { return; }
    UITouch *touch = touches.anyObject;
    CGPoint point = (touch != nil && self.view != nil) ? [touch locationInView:self.view] : CGPointZero;

    /* V0.2.5 抬手快判（AevonAppTwoFrameV205）：快速短划可能整段落在两帧之间，
     * 一次 moved 都没等到就抬手 —— 只要总位移横向占优（8pt 同判据）仍判成立。 */
    if (touch != nil && self.view != nil) {
        double dx = point.x - self.startPoint.x;
        double dy = point.y - self.startPoint.y;
        if (dx <= -8.0 && fabs(dx) >= fabs(dy) * 1.2) {
            self.decided = YES;
            AevonAppLog(@"判向成立：抬手快判 dx=%.0f dy=%.0f（快速短划在帧间结束）→ 取消 App 触摸 + 通知 SB 呼圆盘（AevonAppTwoFrameV205）",
                        dx, dy);
            AevonAppPostRightEdgeTrigger();
            self.state = UIGestureRecognizerStateBegan;
            self.state = UIGestureRecognizerStateEnded;
            return;
        }
    }

    self.decided = YES;
    /* 没判出横向 8pt：轻点或短划。Failed → UIKit 把 began+moved+ended 整段补投，
     * 轻点在抬手时生效（带内轻点的已知代价），App 不会丢事件。 */
    AevonAppLog(@"抬手 (%.0f,%.0f)：未满 8pt 横向 → 整段补投（轻点延迟到抬手生效，App 不丢事件）（AevonAppFailNotifyV206）",
                point.x, point.y);
    AevonAppPostRightEdgeFail();
    self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    /* V0.2.2 取证（AevonAppEarlyJudgeV202）：Aevon(88) 里横向呼盘手指在这一分支
     * 静默消失 —— 谁取消的（滚动容器 pan 抢先 Began / 系统）写清楚，断裂不再隐形 */
    if (self.decided) { return; }
    self.decided = YES;
    AevonAppLog(@"序列被取消：App 内其他手势抢先（最可能是滚动容器 pan ~10pt Began）→ 本指放行（AevonAppEarlyJudgeV202 AevonAppFailNotifyV206）");
    AevonAppPostRightEdgeFail();
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

/* V0.2.4（AevonAppExcludeV204）：逐 App 排除表。
 *
 * plist 已放开到 Classes=[UIApplication]，本表决定「在进程里做不做」：
 *   · 内置前缀：SpringBoard（主插件已覆盖）+ 金融安全敏感 App（越狱检测最重，
 *     接管手势没有任何理由进它们的进程）；
 *   · 用户扩展：com.Aevon 域 `AppSideExcludePrefixes`（CFString 数组），
 *     Filza / 探针里加前缀即可，每次 start 现读（恒假开关纪律）。
 * 命中排除表 = 只加载、不挂识别器、不判向（对 App 零影响），日志留一行痕迹。 */
static NSArray<NSString *> *AevonAppExcludePrefixes(void) {
    NSMutableArray<NSString *> *list = [NSMutableArray arrayWithArray:@[
        @"com.apple.springboard",   /* 主插件已覆盖，App 侧让位 */
        @"com.chinamworld",         /* 建行系 */
        @"com.icbc",                /* 工行 */
        @"com.cmbchina",            /* 招行 */
        @"com.unionpay",            /* 云闪付 */
        @"com.alipay",              /* 支付宝 */
        @"com.chinamworld.bocbth",  /* 中行（同前缀族，冗余保险） */
    ]];
    CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("AppSideExcludePrefixes"), CFSTR("com.Aevon"));
    if (raw != NULL) {
        if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
            CFArrayRef arr = (CFArrayRef)raw;
            for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                CFPropertyListRef item = CFArrayGetValueAtIndex(arr, i);
                if (item != NULL && CFGetTypeID(item) == CFStringGetTypeID()) {
                    NSString *prefix = (__bridge NSString *)item;
                    if (prefix.length > 0) { [list addObject:prefix]; }
                }
            }
        }
        CFRelease(raw);
    }
    return list;
}

- (void)start {
    /* V0.2.4（AevonAppAllAppsV204）：filter 已放开到全部 App（Classes=[UIApplication]），
     * 「进哪些进程」由 plist 管，「在进程里做不做」由这里的分支管：
     *   ① SpringBoard → 主插件已覆盖，App 侧让位（一行日志都不留以外的动作不做）；
     *   ② 排除表命中（内置 + 用户扩展）→ 只加载、不动作；
     *   ③ 其余 → 真接管（开关仍可在设置里整体关）。 */
    if ([gAevonAppBundleID isEqualToString:@"com.apple.springboard"]) {
        return;
    }
    NSArray<NSString *> *excluded = AevonAppExcludePrefixes();
    for (NSString *prefix in excluded) {
        if ([gAevonAppBundleID hasPrefix:prefix]) {
            AevonAppLog(@"%@ 命中排除表（前缀 %@）→ 只加载、不动作（AevonAppExcludeV204）",
                        gAevonAppBundleID ?: @"?", prefix);
            return;
        }
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

    AevonAppLog(@"0.2.4 App 侧已加载（全 App 白名单+排除表）：进程=%@ pid=%d 系统=%@ 通道=%@（AevonAppAllAppsV204）",
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

    /* V0.2.10（AevonAppMountFastV210）：这里原来是**固定等 1 秒**再第一次尝试挂载，
     * 叠加构造阶段那 0.6 秒，冷启动 App 的盲期长达 1.6 秒起步 —— Aevon(96) 抖音
     * 1.8 秒时用户已经在划右缘了，识别器还没挂上，于是「圆盘 + App 同时响应」。
     * 现在改成立刻试一次（keyWindow 通常已经有了），失败交给 0.2 秒一次的快速重试。
     * 挂载本身只是 addGestureRecognizer，代价可以忽略，不需要用时间换稳定。 */
    [self installWithAttempt:1];
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
        /* V0.2.10（AevonAppReadyV210）：每次回到前台都重发一次「在场」。
         * 热启动（App 本来就在后台跑着）不会重新挂载，只靠挂载时那一次广播的话，
         * SB 切回来会以为这一侧是盲的，白白丢掉第一个手势。 */
        AevonAppPostReady();
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
        /* V0.2.7（AevonAppMountRetryV207）：Aevon(93) 实测 QQ 冷启动 ~3 秒后才有可用
         * keyWindow，旧上限 4 次（1+2+3 秒）撑不过启动窗口 —— 用户在 QQ 划右缘时
         * 识别器还没挂上 = App 侧全盲，global 兜底呼盘 + QQ 跟着动。
         * V0.2.10（AevonAppMountFastV210）：间隔 0.5s → **0.2s**、上限 40 → 80 次
         * （仍是 16 秒窗口）。盲期越短，「圆盘和 App 抢同一根手指」的窗口就越小。 */
        if (attempt < 80) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self_ = weakSelf;
                if (self_ == nil) { return; }
                [self_ installWithAttempt:attempt + 1];
            });
        } else {
            AevonAppLog(@"16 秒内始终取不到 keyWindow → 放弃挂载（App 侧保持只加载不动作）");
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
    /* V0.2.10（AevonAppReadyV210）：挂载成功 → 立刻告诉 SpringBoard「这一侧在场」。
     * SB 收到后才允许在这台 App 上呼盘；没有这条信号的 App 会被当成盲期而放弃呼盘
     * （宁可少呼一次，也绝不让圆盘和 App 同时响应同一根手指）。 */
    AevonAppPostReady();
    AevonAppLog(@"识别器已挂载：窗口=%@ 尺寸=%.0fx%.0f 带宽=%.0f 带高=%.0f%% 模式=真接管（delaysTouchesBegan=YES cancelsTouchesInView=YES，判向失败整段补投；已广播 appready）（AevonAppTakeoverV201 AevonAppReadyV210 AevonAppMountFastV210）",
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

            /* V0.2.10（AevonAppMountFastV210）：0.6 秒 → 0.12 秒。
             * 这一秒级等待原本是为了「别在 App 启动路径上抢主线程」，但真正要做的
             * 只有取 keyWindow + addGestureRecognizer 两件事，等 0.6 秒纯属白送盲期。 */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
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
