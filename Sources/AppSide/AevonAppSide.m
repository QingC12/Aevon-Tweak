#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdio.h>
#import <string.h>
#import <math.h>
#import <time.h>
#import <mach/mach_time.h>
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
/* V0.2.72（AevonFloatBandWideV272，用户 Aevon(44) #1）：浮窗手势带加宽
 * （带 30→44 / 底 44→64 / 顶 8→20 / 外扩 10→22pt）。 */
__attribute__((used)) static const char AevonFloatBandWideV272Marker[] = "AevonFloatBandWideV272";
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
/* V0.2.11 手势环境归还（Aevon(97)：关圆盘后全屏 App 划不动，必须切应用才恢复） */
__attribute__((used)) static const char AevonAppReleaseCleanV211Marker[] = "AevonAppReleaseCleanV211";
__attribute__((used)) static const char AevonAppRingCloseReleaseV211Marker[] = "AevonAppRingCloseReleaseV211";
__attribute__((used)) static const char AevonAppNoBlockIdleV211Marker[] = "AevonAppNoBlockIdleV211";
/* V0.2.12（历史串只加不能改）：Aevon(98) 事故的收尾判据 —— 圆盘状态位轮询 */
__attribute__((used)) static const char AevonAppRingGoneGuardV212Marker[] = "AevonAppRingGoneGuardV212";
/* V0.2.20（Aevon(105) 判读）：几何只认共享内存 + 读不到 fail-closed。
 * 标记必须是 ASCII used 常量 —— 只写在 ObjC 中文日志字面量里的标记落在
 * __ustring（UTF-16），CI 的 strings 对它检测不稳定（run 40281434515 实锤：
 * 日志字面量里的 AevonAppGeomNotifyV220 查不到，断言误报缺标记）。 */
__attribute__((used)) static const char AevonAppGeomNotifyV220Marker[] = "AevonAppGeomNotifyV220";
__attribute__((used)) static const char AevonAppGeomFailClosedV220Marker[] = "AevonAppGeomFailClosedV220";
/* V0.2.33（AevonAppSceneProbeV233）：App 端 scene 连接探针（只读取证 + 透传）。
 * Aevon(8) 判读：0.2.32 自建场景 SB 侧链路全绿，系统 App 渲染成功、第三方 Sileo
 * 黑屏且取证串与系统 App 完全一致 —— 卡点在 App 端 scene session 连接层。
 * 本探针回答两个问题（下轮日志直接判读）：
 *   Q1 App 端收到第二场景的连接请求了吗（拦截 delegate 的
 *      application:configurationForConnectingSceneSession:options:，只记日志全透传）；
 *   Q2 场景生命周期事件走到了哪一步（UISceneWillConnect/DidActivate/DidDisconnect）。 */
__attribute__((used)) static const char AevonAppSceneProbeV233Marker[] = "AevonAppSceneProbeV233";
__attribute__((used)) static const char AevonAppSceneSwizzleV233Marker[] = "AevonAppSceneSwizzleV233";
/* V0.2.34（AevonSelfSceneTakeoverV234 / AevonAppSceneTakeoverV234，0.2.33 真机判型）：
 * 单场景 App 不为第二场景建 window 是黑屏直接原因。对策 = App 侧收到
 * com.aevon.selfscene.created 后轮询 connectedScenes，发现自建 UIWindowScene：
 *   - App 已为它建了 window（多场景支持，如设置/GitHub）→ 不动，原路径工作；
 *   - 没建（单场景 App）→ 把主 UIWindow setWindowScene 搬进自建场景 +
 *     frame = 画布（scene.coordinateSpace.bounds），画面立刻出现在浮窗；
 * 收到 selfscene.destroyed → 搬回主场景（否则 window 挂在断开场景上 = 回前台黑屏）。 */
__attribute__((used)) static const char AevonAppSceneTakeoverV234Marker[] = "AevonAppSceneTakeoverV234";

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

#pragma mark - scene 连接探针（V0.2.33，AevonAppSceneProbeV233）

/* session / options / scene 是否属于 Aevon 自建场景（描述串含前缀即命中，
 * 只读不改 —— 探针纪律）。 */
static BOOL AevonAppSceneIsOurs(id obj) {
    if (obj == nil) { return NO; }
    @try {
        NSString *desc = [obj description];
        return [desc rangeOfString:@"com.aevon.float-"].location != NSNotFound;
    } @catch (NSException *exception) { return NO; }
}

static BOOL gAevonAppSceneSwizzled = NO;

/* 拦截 delegate 的 application:configurationForConnectingSceneSession:options:。
 * 只在 Aevon 自建场景的连接上记日志，其余全部原样透传（零行为改动）。
 * imp_implementationWithBlock：block 首参是 receiver、后续是方法参数（无 _cmd），
 * 原 IMP 用固定 SEL 手动回发。任何异常都吞掉 —— 探针绝不能影响宿主 App。 */
static void AevonAppSceneSwizzleConnecting(id delegate) {
    if (gAevonAppSceneSwizzled || delegate == nil) { return; }
    @try {
        Class cls = object_getClass(delegate);
        SEL sel = NSSelectorFromString(@"application:configurationForConnectingSceneSession:options:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m == NULL) {
            AevonAppLog(@"scene 探针：delegate(%@) 未实现 configurationForConnecting（老式 AppDelegate，UIKit 自动桥接）（AevonAppSceneSwizzleV233）",
                        NSStringFromClass(cls) ?: @"?");
            return;
        }
        IMP orig = method_getImplementation(m);
        __block IMP origIMP = orig;
        id probeBlock = ^(id self_, id application, id connectingSceneSession, id options) {
            BOOL ours = AevonAppSceneIsOurs(connectingSceneSession) || AevonAppSceneIsOurs(options);
            id (*fn)(id, SEL, id, id, id) = (id (*)(id, SEL, id, id, id))origIMP;
            id cfg = fn(self_,
                        NSSelectorFromString(@"application:configurationForConnectingSceneSession:options:"),
                        application, connectingSceneSession, options);
            if (ours) {
                NSString *delegateClass = @"?";
                @try { delegateClass = [cfg valueForKey:@"delegateClass"] ?: @"nil"; }
                @catch (NSException *e) { delegateClass = @"(取不到)"; }
                AevonAppLog(@"scene 连接请求（App 端已收到）：session=%@ options=%@ → 配置=%@ delegateClass=%@（AevonAppSceneSwizzleV233）",
                            connectingSceneSession, options, cfg ?: @"nil", delegateClass);
            }
            return cfg;
        };
        method_setImplementation(m, imp_implementationWithBlock(probeBlock));
        gAevonAppSceneSwizzled = YES;
        AevonAppLog(@"scene 探针：已挂 configurationForConnecting 拦截（delegate=%@，只记日志全透传）（AevonAppSceneSwizzleV233）",
                    NSStringFromClass(cls) ?: @"?");
    } @catch (NSException *exception) {
        AevonAppLog(@"scene 探针安装异常：%@（不影响宿主）", exception.reason ?: @"未知");
    }
}

/* 场景生命周期通知观察（WillConnect / DidActivate / DidDisconnect）。
 * 判读规则：黑屏 App 上 WillConnect 有 = 连接到了 App 端，卡在 session 配置/建窗；
 * WillConnect 无 = 连接在更早环节被拒（SB clientProvider 或 App 端 UIKit 入口）。 */
static void AevonAppSceneInstallObservers(void) {
    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:@"UISceneWillConnectNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            if (AevonAppSceneIsOurs(note.object)) {
                AevonAppLog(@"scene 生命周期：WillConnect（连接已进 App 端生命周期）（AevonAppSceneProbeV233）");
            }
        }];
        [nc addObserverForName:@"UISceneDidActivateNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            if (AevonAppSceneIsOurs(note.object)) {
                AevonAppLog(@"scene 生命周期：DidActivate（场景已激活）（AevonAppSceneProbeV233）");
            }
        }];
        [nc addObserverForName:@"UISceneDidDisconnectNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            if (AevonAppSceneIsOurs(note.object)) {
                AevonAppLog(@"scene 生命周期：DidDisconnect（场景断开）（AevonAppSceneProbeV233）");
            }
        }];
    } @catch (NSException *exception) {
        AevonAppLog(@"scene 通知观察安装异常：%@（不影响宿主）", exception.reason ?: @"未知");
    }
}

/* V0.2.34 窗口搬家（AevonAppSceneTakeoverV234）。
 *
 * 0.2.33 真机判型（Aevon(9)）：设置/GitHub 成功、BatteryInfo/Filza/抖音/Sileo 黑屏，
 * 而 SB 侧取证串四者完全一致 —— 黑屏与否取决于 App 端是否为第二场景建了 window：
 * 多场景感知 App（设置/GitHub）自己给自建场景建了 window → 有画面；
 * 单场景 App（绝大多数第三方）不为第二场景建 window → 黑。
 *
 * 修复 = 窗口搬家：收到 com.aevon.selfscene.created 后轮询 connectedScenes
 * 发现自建 UIWindowScene，若 App 没为它建 window，就把主 UIWindow
 * setWindowScene 搬进自建场景 + frame = 画布（公开 API，可逆）；
 * 收到 com.aevon.selfscene.destroyed（SB 销毁场景前 0.35s 广播）立即搬回，
 * 否则 window 挂在已断开的场景上，App 回前台就是黑屏。
 * App 已自建 window（多场景支持）时绝不搬家，原路径照常工作。
 * 开关：com.Aevon 域 SceneWindowTakeover（无键=开）。 */

static BOOL gAevonAppTakeoverActive = NO;      /* 轮询进行中（防重入） */
static BOOL gAevonAppTakeoverMoved = NO;       /* 已完成搬家（window 在自建场景里） */
static __weak UIWindow *gAevonAppTakeoverWindow = nil;
static __weak UIWindowScene *gAevonAppOriginalScene = nil;
static CGRect gAevonAppOriginalFrame = {{0.0, 0.0}, {0.0, 0.0}};   /* 显式零 rect（-Wmissing-braces） */

/* 在 connectedScenes 里找 Aevon 自建场景（description 含前缀即命中）。
 * 返回 UIWindowScene；找不到返回 nil。 */
static UIWindowScene *AevonAppSceneFindOurs(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSSet *sessions = [app valueForKey:@"connectedScenes"];
        if (sessions == nil) { return nil; }
        for (id session in sessions) {
            id scene = nil;
            @try { scene = [session valueForKey:@"scene"]; } @catch (NSException *e) { scene = nil; }
            if (scene == nil) { continue; }
            if (AevonAppSceneIsOurs(scene)) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    return (UIWindowScene *)scene;
                }
            }
        }
    } @catch (NSException *exception) { /* 只读，任何异常都吞 */ }
    return nil;
}

/* 搬家：把主 window（所有非自建场景里 frame 最大的 UIWindow）搬进自建场景。
 * 返回 YES = 终态（搬完 / 多场景支持 / 异常），NO = 本轮未定（启动早期，继续等）。 */
static BOOL AevonAppSceneTakeoverMove(UIWindowScene *oursScene) {
    if (gAevonAppTakeoverMoved) { return YES; }

    /* 多场景 App 已为自建场景建了 window → 原路径工作，不搬家 */
    NSArray *oursWindows = nil;
    @try { oursWindows = [oursScene valueForKey:@"windows"]; } @catch (NSException *e) { oursWindows = nil; }
    if (oursWindows.count > 0) {
        AevonAppLog(@"窗口搬家：App 已为自建场景建了 %lu 个 window（多场景支持）→ 不搬家，原路径工作（AevonAppSceneTakeoverV234）",
                    (unsigned long)oursWindows.count);
        return YES;
    }

    /* 找主 window：遍历所有场景，取非自建场景里 frame 最大的 UIWindow */
    UIWindow *main = nil;
    CGRect mainFrame = CGRectZero;
    @try {
        NSSet *sessions = [[UIApplication sharedApplication] valueForKey:@"connectedScenes"];
        for (id session in sessions) {
            id scene = nil;
            @try { scene = [session valueForKey:@"scene"]; } @catch (NSException *e) { scene = nil; }
            if (scene == nil || ![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            if (AevonAppSceneIsOurs(scene)) { continue; }
            NSArray *windows = nil;
            @try { windows = [scene valueForKey:@"windows"]; } @catch (NSException *e) { windows = nil; }
            for (UIWindow *w in windows) {
                if (![w isKindOfClass:[UIWindow class]]) { continue; }
                CGFloat area = w.frame.size.width * w.frame.size.height;
                if (main == nil || area > mainFrame.size.width * mainFrame.size.height) {
                    main = w;
                    mainFrame = w.frame;
                }
            }
        }
    } @catch (NSException *exception) { main = nil; }
    if (main == nil) {
        AevonAppLog(@"窗口搬家：自建场景已连上但找不到主 window（启动早期，等下一轮）（AevonAppSceneTakeoverV234）");
        return NO;
    }

    CGRect canvas = oursScene.coordinateSpace.bounds;
    @try {
        gAevonAppOriginalScene = main.windowScene;
        gAevonAppOriginalFrame = main.frame;
        CGRect before = main.frame;
        [main setWindowScene:oursScene];
        main.frame = canvas;
        gAevonAppTakeoverWindow = main;
        gAevonAppTakeoverMoved = YES;
        AevonAppLog(@"窗口搬家：主 window 已搬入自建场景（frame %@ → %@）（AevonAppSceneTakeoverV234）",
                    NSStringFromCGRect(before), NSStringFromCGRect(main.frame));
    } @catch (NSException *exception) {
        AevonAppLog(@"窗口搬家异常：%@（不影响宿主）（AevonAppSceneTakeoverV234）", exception.reason ?: @"未知");
        return YES;
    }
    return YES;
}

/* 搬回：SB 销毁自建场景前 0.35s 广播，把 window 搬回主场景原位。 */
static void AevonAppSceneTakeoverRestore(void) {
    if (!gAevonAppTakeoverMoved) { return; }
    UIWindow *w = gAevonAppTakeoverWindow;
    UIWindowScene *origin = gAevonAppOriginalScene;
    gAevonAppTakeoverMoved = NO;
    if (w == nil || origin == nil) { return; }
    @try {
        CGRect target = gAevonAppOriginalFrame;
        [w setWindowScene:origin];
        w.frame = target;
        AevonAppLog(@"窗口搬回：主 window 已搬回原场景（frame %@）（AevonAppSceneTakeoverV234）",
                    NSStringFromCGRect(target));
    } @catch (NSException *exception) {
        AevonAppLog(@"窗口搬回异常：%@（AevonAppSceneTakeoverV234）", exception.reason ?: @"未知");
    }
}

/* 轮询：0.5s × 16 次（8 秒覆盖 SB 创建场景 + App 端连接全过程）。
 * 找到自建场景 → 搬家（或判定多场景支持）→ 停；
 * 超时未找到 → 记「自建场景未达 App 端」，这是连接被 App 端拒绝的证据。 */
static NSInteger gAevonAppTakeoverTick = 0;
static void AevonAppSceneTakeoverPollReset(void) { gAevonAppTakeoverTick = 0; }
static void AevonAppSceneTakeoverPoll(void) {
    gAevonAppTakeoverTick += 1;
    NSInteger tick = gAevonAppTakeoverTick;
    UIWindowScene *ours = AevonAppSceneFindOurs();
    if (ours != nil) {
        AevonAppLog(@"窗口搬家：自建场景已连上 App 端（第 %ld 次探测）（AevonAppSceneTakeoverV234）", (long)tick);
        BOOL settled = AevonAppSceneTakeoverMove(ours);
        if (settled) {
            gAevonAppTakeoverActive = NO;
            return;
        }
        /* 未定态（启动早期）：继续轮询等主 window 出现 */
    }
    if (tick >= 16) {
        AevonAppLog(@"窗口搬家：8 秒内自建场景未连上 App 端（connectedScenes 无自建场景）= 连接被 App 端 UIKit 拒绝（AevonAppSceneTakeoverV234）");
        gAevonAppTakeoverActive = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gAevonAppTakeoverActive) { AevonAppSceneTakeoverPoll(); }
    });
}

/* Darwin 通知回调（C 上下文，只派发不干活）。 */
static void AevonAppSceneTakeoverNotify(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    if (name == NULL) { return; }
    NSString *n = [NSString stringWithString:(__bridge NSString *)name];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([n isEqualToString:@"com.aevon.selfscene.created"]) {
            if (!AevonAppPrefBool(@"SceneWindowTakeover", YES)) {
                AevonAppLog(@"窗口搬家：SceneWindowTakeover=关，只记录不搬（AevonAppSceneTakeoverV234）");
                return;
            }
            if (gAevonAppTakeoverActive || gAevonAppTakeoverMoved) { return; }
            gAevonAppTakeoverActive = YES;
            AevonAppSceneTakeoverPollReset();
            AevonAppSceneTakeoverPoll();
        } else if ([n isEqualToString:@"com.aevon.selfscene.destroyed"]) {
            AevonAppSceneTakeoverRestore();
        }
    });
}

static void AevonAppSceneTakeoverInstall(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonAppSceneTakeoverNotify,
                                    CFSTR("com.aevon.selfscene.created"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonAppSceneTakeoverNotify,
                                    CFSTR("com.aevon.selfscene.destroyed"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

/* V0.2.35（AevonAppTakeoverAmbientV235）：安静轮询兜底。
 * 0.2.34 真机疑点：created 通知只有 Sileo 进程触发了轮询，设置/BatteryInfo 进程
 * 无声无息（同一段注册代码、同样的主线程注册，通知没进回调 —— 送达不可靠）。
 * 修法 = 不把鸡蛋放通知一个篮子：每 1 秒看一眼 connectedScenes，
 *   · 发现自建场景且还没搬 → 走与通知相同的 takeover 入口（防重入已有）；
 *   · 已搬但场景消失（destroyed 广播丢失）→ 搬回。
 * 平时零日志零动作（KVC 枚举两个场景，每秒一次，成本可忽略）。 */
__attribute__((used)) static const char AevonAppTakeoverAmbientV235Marker[] = "AevonAppTakeoverAmbientV235";

static void AevonAppSceneTakeoverAmbientPoll(void) {
    @try {
        if (!gAevonAppTakeoverActive && !gAevonAppTakeoverMoved) {
            UIWindowScene *ours = AevonAppSceneFindOurs();
            if (ours != nil) {
                AevonAppLog(@"窗口搬家：安静轮询发现自建场景（created 通知未达兜底）（AevonAppTakeoverAmbientV235）");
                gAevonAppTakeoverActive = YES;
                AevonAppSceneTakeoverPollReset();
                AevonAppSceneTakeoverPoll();
            }
        } else if (gAevonAppTakeoverMoved && AevonAppSceneFindOurs() == nil) {
            AevonAppLog(@"窗口搬家：自建场景已消失（destroyed 通知未达兜底）→ 搬回（AevonAppTakeoverAmbientV235）");
            AevonAppSceneTakeoverRestore();
        }
    } @catch (NSException *exception) {
        /* 只读轮询，任何异常都吞 */
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonAppSceneTakeoverAmbientPoll();
    });
}

/* V0.2.51（AevonGripOnlyV251）：AevonAppInFloatingWindow 已随识别器体系退役 ——
 * 呼盘唯一入口 = 圆盘把手（视图命中天然路由），App 侧不再需要「浮窗中不接管」判据。 */

#pragma mark - 主控制器

@interface AevonAppSide : NSObject
+ (instancetype)sharedInstance;
- (void)start;
@end

@implementation AevonAppSide
/* V0.2.51（AevonGripOnlyV251）：识别器体系整建制退役 —— 呼盘唯一入口 = 圆盘把手，
 * App 侧不再挂任何手势识别器；保留 scene cap / gate / probe / takeover / screen fit。 */

+ (instancetype)sharedInstance {
    static AevonAppSide *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AevonAppSide alloc] init];
    });
    return instance;
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

/* V0.2.41（AevonAppSceneCapV241）：场景能力登记 —— 判据落进程内，落盘给 SB 读。
 * 0.2.33 探针 + 0.2.31~0.40 五轮真机矩阵闭环：App 的 delegate 实现
 * application:configurationForConnectingSceneSession:options: ⇔ 自建场景被接受
 * （设置/文件/GitHub 实现 → 真重排；Sileo/Filza 未实现 → 连接被拒黑屏）。
 * 静态判据五版全翻车：设置 manifest 无 delegate 类名却成功、Sileo 二进制含该串
 * 却被拒、贴吧纯净版扫不到却成功 —— 只有进程内 respondsToSelector 与成败 100% 对齐。
 * 落地：V0.2.65 起**只在进程内判定 + 打日志**，不再往日志目录写能力表文件
 * （见下方 AevonNoCapsFileV265）。delegate 未就绪（nil）不出结论，
 * 绝不把「判断不了」记成 0。 */
__attribute__((used)) static const char AevonAppSceneCapV241Marker[] = "AevonAppSceneCapV241";

static void AevonAppSceneCapRegistry(void) {
    @try {
        id delegate = [[UIApplication sharedApplication] delegate];
        if (delegate == nil) {
            AevonAppLog(@"场景能力登记：delegate 尚未就绪，本轮不写（AevonAppSceneCapV241）");
            return;
        }
        SEL sel = NSSelectorFromString(@"application:configurationForConnectingSceneSession:options:");
        BOOL cap = [delegate respondsToSelector:sel];
        NSString *bid = gAevonAppBundleID;
        if (bid.length == 0) { return; }
        /* V0.2.65（AevonNoCapsFileV265，用户 Aevon(38) #10「移除日志目录中 Aevon_caps.txt」）：
         * 这张 `bundleID=1/0` 的能力表是 0.2.41 给「自建场景还是主场景改画布」做判据用的；
         * 0.2.64 起 S2（主场景改画布）已定档常开、设置页开关都移除了，判据不再被读。
         * 于是这张盘上文件只剩「污染日志目录」这一个作用 —— 这里只保留进程内判定与日志，
         * 不再落盘，并顺手把历史遗留的两份都删掉。 */
        AevonAppLog(@"场景能力登记：cap=%d（delegate=%@，仅进程内，不再落盘）"
                    @"（AevonAppSceneCapV241 AevonNoCapsFileV265）",
                    cap ? 1 : 0, NSStringFromClass([delegate class]));
        static BOOL capsCleaned = NO;
        if (!capsCleaned) {
            capsCleaned = YES;
            for (NSString *legacy in @[@"/var/mobile/aevon_caps.txt", @"/var/mobile/Aevon_caps.txt"]) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) {
                    [[NSFileManager defaultManager] removeItemAtPath:legacy error:NULL];
                    AevonAppLog(@"已删除历史遗留的能力表文件 %@（AevonNoCapsFileV265）", legacy);
                }
            }
        }
    } @catch (NSException *exception) {
        AevonAppLog(@"场景能力登记异常：%@（AevonAppSceneCapV241）", exception.name);
    }
}

/* V0.2.42（AevonSceneGateV242）：S1 —— 打开 App 端「场景请求闸」。
 * 来源：TrollPad（khanhduytran0，开源 iOS 14+，把 iPad 多任务移植到 iPhone）的两条 hook。
 * 0.2.34 窗口搬家失败的死因是「自建场景根本没连上 App 端」（connectedScenes 8 秒里
 * 没有它），而 UIKit 拒绝外部场景请求的两道闸都在 App 进程内：
 *   ① UIApplication.supportsMultipleScenes —— 老式 App 恒 NO（无 manifest 即 NO）；
 *   ② delegate 的 application:configurationForConnectingSceneSession:options: ——
 *      老式 AppDelegate 没实现，UIKit 自动桥接只认主场景。
 * 本函数在开关打开时把两道闸都放开：① swizzle 成 YES；② 给老式 delegate 补实现，
 * 返回一个 delegateClass=UIResponder 的空配置（内容由 0.2.34 窗口搬家搬进来）。
 * 只在 SceneRouteForceSelf=YES（S1 试验档）时生效；默认关 —— 日常使用一个字节都不碰，
 * 也就不可能影响 App 的主场景启动路径（补方法是有污染面的一步，所以必须锁在试验档里）。 */
__attribute__((used)) static const char AevonSceneGateV242Marker[] = "AevonSceneGateV242";

static BOOL (*gAevonOrigSupportsMultipleScenes)(id, SEL) = NULL;

static BOOL AevonGateSupportsMultipleScenes(id self, SEL _cmd) {
    if (!AevonAppPrefBool(@"SceneRouteForceSelf", NO)) {
        return gAevonOrigSupportsMultipleScenes ? gAevonOrigSupportsMultipleScenes(self, _cmd) : NO;
    }
    return YES;
}

static id AevonGateConfigurationForConnecting(id self, SEL _cmd,
                                              id application, id session, id options) {
    UISceneConfiguration *config =
        [[UISceneConfiguration alloc] initWithName:@"AevonSelfScene"
                                       sessionRole:@"UIWindowSceneSessionRoleApplication"];
    Class sceneCls = NSClassFromString(@"UIWindowScene");
    if (sceneCls != Nil) { config.sceneClass = sceneCls; }
    Class delCls = NSClassFromString(@"UIResponder");
    if (delCls != Nil) { config.delegateClass = delCls; }
    AevonAppLog(@"场景闸：已为外部场景请求返回配置（session=%@，scene=%d，delegate=%d）（AevonSceneGateV242）",
                session ? NSStringFromClass([session class]) : @"nil",
                sceneCls != Nil ? 1 : 0, delCls != Nil ? 1 : 0);
    return config;
}

static void AevonAppSceneGateApply(void) {
    if (!AevonAppPrefBool(@"SceneRouteForceSelf", NO)) {
        AevonAppLog(@"场景闸：未开（SceneRouteForceSelf=NO，S1 试验档未启用）（AevonSceneGateV242）");
        return;
    }
    @try {
        Method m = class_getInstanceMethod([UIApplication class], @selector(supportsMultipleScenes));
        if (m != NULL && gAevonOrigSupportsMultipleScenes == NULL) {
            gAevonOrigSupportsMultipleScenes = (BOOL (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)AevonGateSupportsMultipleScenes);
            AevonAppLog(@"场景闸：supportsMultipleScenes 已强制 YES（AevonSceneGateV242）");
        }
        id delegate = [[UIApplication sharedApplication] delegate];
        SEL sel = NSSelectorFromString(@"application:configurationForConnectingSceneSession:options:");
        if (delegate != nil && ![delegate respondsToSelector:sel]) {
            Class cls = [delegate class];
            BOOL added = class_addMethod(cls, sel,
                                         (IMP)AevonGateConfigurationForConnecting, "@@:@@@");
            AevonAppLog(@"场景闸：给 %@ 补 configurationForConnecting（added=%d）（AevonSceneGateV242）",
                        NSStringFromClass(cls), added ? 1 : 0);
        } else if (delegate != nil) {
            AevonAppLog(@"场景闸：delegate %@ 本就实现 configurationForConnecting，不用补（AevonSceneGateV242）",
                        NSStringFromClass([delegate class]));
        }
    } @catch (NSException *exception) {
        AevonAppLog(@"场景闸异常：%@（AevonSceneGateV242）", exception.name);
    }
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
    /* V0.2.41（AevonAppSceneCapV241）：场景能力登记必须在排除表之前 ——
     * 排除表里的 App（银行等）同样可能被浮窗打开，也要有能力记录。
     * 两次：0.6s（多数 App delegate 已就绪）+ 2.5s（慢启动兜底），幂等。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonAppSceneCapRegistry();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonAppSceneCapRegistry();
    });
    /* V0.2.42（AevonSceneGateV242）：S1 试验档的场景闸。必须在任何场景请求到达前装好
     * （SB 拉起 App 后 ~0.15s 才建自建场景，start 在更早的 UIApplication 初始化期跑）；
     * 开关关闭时只打一行日志、一个字节都不碰。 */
    AevonAppSceneGateApply();
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

    /* V0.2.33（AevonAppSceneProbeV233）：scene 连接探针，只读取证。
     * 通知观察无条件装；delegate 拦截此刻装一次，delegate 未就绪时 1.5s 后再试一次
     * （幂等，装过即止）。探针对非 Aevon 场景零输出零改动。 */
    AevonAppSceneInstallObservers();
    AevonAppSceneSwizzleConnecting([[UIApplication sharedApplication] delegate]);
    /* V0.2.34（AevonAppSceneTakeoverV234）：窗口搬家（单场景 App 黑屏根治）。
     * 只收 Darwin 通知动作，平时零开销；SceneWindowTakeover 键可关（无键=开）。 */
    AevonAppSceneTakeoverInstall();
    /* V0.2.35（AevonAppTakeoverAmbientV235）：安静轮询兜底（通知送达不可靠）。
     * 延迟 2 秒再起：躲开启动最忙段。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonAppSceneTakeoverAmbientPoll();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonAppSceneSwizzleConnecting([[UIApplication sharedApplication] delegate]);
    });

    AevonAppLog(@"0.2.4 App 侧已加载（全 App 白名单+排除表）：进程=%@ pid=%d 系统=%@ 通道=%@（AevonAppAllAppsV204）",
                gAevonAppBundleID, (int)getpid(),
                [UIDevice currentDevice].systemVersion ?: @"?",
                gAevonAppChannel);

}

@end

#pragma mark - V0.2.49 屏幕尺寸贴合浮窗（AevonAppScreenFitV249）

/* Aevon(24)：「悬浮窗打开抖音时点击分享按钮，二级页面显示不全，无法查看整个分享菜单」
 *          「抖音部分视频还是会出现整体上移（能不能改为抖音视频画面自动重排以适应
 *            小胖屏的尺寸）」
 *
 * 这两条是同一个根因，而且是我们自己造的：**场景画布已经是 430×737，但 App 里
 * `UIScreen.main.bounds` 还是 430×932**。凡是按「屏幕高度」算尺寸的 UI（抖音的分享
 * 面板高度、视频区纵向锚点）都按 932 算，于是底部 195pt 落在画布外 —— 分享菜单被裁、
 * 视频被顶到上半屏。S2 改画布只改得动「场景」，改不动这条全局查询。
 *
 * 做法：在**被浮窗承载的那个 App 进程里**把 `-[UIScreen bounds]` 报成画布尺寸
 * （宽 = 真实屏宽，高 = 宽 × 12/7，与浮窗画布同一比例）。三条纪律：
 *   ① **只改 bounds 这一个选择子** —— 像素级尺寸与 scale 一个字节都不碰
 *      （动了它们就动到渲染缓冲，画面会变形甚至黑屏）；
 *   ② **只在「这个 App 正被浮窗承载」时生效**（判据 = com.Aevon 域的 AevonFloatBundle
 *      等于自己，与 0.2.9 的识别器退让用同一个键），关窗后立刻恢复真实值；
 *   ③ 全链 @try + 0.5 秒节流的偏好读取，判据读不到就是「关」——
 *      出错方向必须是「不介入」，绝不能把整机 App 的屏幕尺寸改坏。
 *
 * 关窗后 App 的下一次布局会重新拿到真实 430×932；由于关窗流程会先把场景画布还原成
 * 整屏并等抖动走完（AevonCloseSettleV249），不会留下残留。 */
__attribute__((used)) static const char AevonAppScreenFitV249Marker[] = "AevonAppScreenFitV249";
__attribute__((used)) static const char AevonAppScreenFitFailV249Marker[] = "AevonAppScreenFitFailV249";

static IMP gAevonScreenBoundsOrigIMP = NULL;
static BOOL gAevonScreenFitOn = NO;
static BOOL gAevonScreenFitLogged = NO;
static BOOL gAevonScreenFitRefreshing = NO;
static CFTimeInterval gAevonScreenFitCheckedAt = 0;
/* V0.2.64（AevonFitDebounceV264）：承载状态去抖 —— 新值要稳 0.30s 才承认 */
static BOOL gAevonScreenFitPendingOn = NO;
static CFTimeInterval gAevonScreenFitPendingSince = 0;

/* 与 SB 侧 AevonFloatStageHash 必须逐字节一致（FNV-1a 32 位，0 = 没有浮窗）。 */
static uint32_t AevonAppFloatStageHash(NSString *text) {
    if (text.length == 0) { return 0; }
    const char *utf8 = text.UTF8String;
    if (utf8 == NULL) { return 0; }
    uint32_t hash = 2166136261u;
    for (const char *p = utf8; *p != '\0'; p++) {
        hash ^= (uint32_t)(unsigned char)(*p);
        hash *= 16777619u;
    }
    return hash == 0 ? 1u : hash;
}

/* 「本 App 是否正被浮窗承载」——两条通道取或：共享内存（沙盒必可读）+ 偏好域
 * （0.2.9 起验证可用，作为老环境兜底）。任何一条成立就开贴合。 */
static BOOL AevonAppIsFloatHosted(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.floatstage", &token);
    });
    if (token >= 0) {
        uint64_t stage = 0;
        if (notify_get_state(token, &stage) == NOTIFY_STATUS_OK) {
            if (stage == (uint64_t)AevonAppFloatStageHash(gAevonAppBundleID)) { return YES; }
        }
    }
    NSString *bundle = AevonAppPrefString(@"AevonFloatBundle");
    return (bundle.length > 0 && [bundle isEqualToString:gAevonAppBundleID]);
}

/* V0.2.50（AevonAppFitRelayoutV250）：贴合状态翻转时**让窗口立刻重排一遍**。
 *
 * Aevon(25) 第 1 条：「悬浮窗打开过的应用关闭悬浮窗后全屏打开时依旧会黑屏，只能通过
 * 关闭后台卡片重新打开才会恢复」。历史档案里同一现象出现过（V0.0.57 记录：
 * 「改 keyWindow / 场景尺寸会让 App 真的变成小窗，关窗后残留 → 全屏打开大面积黑屏」）。
 *
 * 成因链：本进程在浮窗期间按 **430×737** 排好了版；关窗后我们把贴合关掉，
 * `UIScreen.bounds` 立刻回到 430×932 —— 但**没有任何东西会因此触发重排**
 * （UIKit 的窗口几何来自场景，不来自 UIScreen）。于是进程里留着
 * 「按 737 高排版、窗口却是 932 高」的残局，全屏打开就是黑/半黑，只有杀进程才重建。
 *
 * 这里在状态翻转的那一刻主动把每个窗口敲一遍（setNeedsLayout + layoutIfNeeded），
 * 顺手把 rootViewController 的 view 也敲一遍 —— 一次翻转只敲一次，不是轮询。 */
__attribute__((used)) static const char AevonAppFitRelayoutV250Marker[] = "AevonAppFitRelayoutV250";
/* V0.2.62：Objective-C 里带中文的 @"…" 会被编成 UTF-16（strings 搜不到），
 * 所以新标记一律走纯 ASCII 的 used 数组 —— 0.2.61 已经在这上面烧过一次构建。 */
__attribute__((used)) static const char AevonFitFrameBackV262Marker[] = "AevonFitFrameBackV262";

/* 前向声明（V0.2.62）：下面两个函数定义在文件后部，nudge / 键盘对齐都要用 ——
 * C99 不支持隐式声明（0.2.52 同款坑，编译期才暴露）。必须放在**第一个调用点之前**。 */
static CGSize AevonRealScreenSize(void);
static BOOL AevonIsKeyboardWindow(UIWindow *window);

static void AevonScreenFitNudgeLayout(BOOL nowOn) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { return; }
        CGSize realScreen = AevonRealScreenSize();
        NSInteger touched = 0;
        NSInteger fixed = 0;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                /* V0.2.62（AevonFitFrameBackV262，用户 Aevon(36) #6「设置黑屏依然存在」）：
                 * 关窗那一刻光敲 layout 不够 —— UIKit 的窗口几何来自场景，场景一旦被
                 * 我们按 737 高写过，回来时**没人把窗口 frame 改回 932**。Aevon(36) 日志
                 * 11:05:12.963 只有「已让 3 个窗口立即重排」，而用户看到的是黑屏。
                 * 这里在「关」的那一拍把明显小于真实屏幕的窗口直接拉回整屏
                 * （键盘窗口除外：它本来就该是矮条，拉成整屏会盖满全屏）。 */
                if (!nowOn && !AevonIsKeyboardWindow(window) && !window.hidden
                    && realScreen.width > 100 && realScreen.height > 200) {
                    CGRect f = window.frame;
                    if (f.size.width < realScreen.width - 4 || f.size.height < realScreen.height - 4) {
                        window.frame = CGRectMake(0, 0, realScreen.width, realScreen.height);
                        fixed += 1;
                    }
                }
                [window setNeedsLayout];
                [window layoutIfNeeded];
                UIView *root = window.rootViewController.view;
                if (root != nil) {
                    [root setNeedsLayout];
                    [root layoutIfNeeded];
                }
                touched += 1;
            }
        }
        AevonAppLog(@"屏幕贴合：状态翻转 → %@，已让 %ld 个窗口立即重排（其中 %ld 个拉回整屏）"
                    @"（防止「按画布排版、占整屏窗口」的残留黑屏）"
                    @"（AevonAppFitRelayoutV250 AevonFitFrameBackV262）",
                    nowOn ? @"开（改报画布尺寸）" : @"关（回到真实屏幕尺寸）",
                    (long)touched, (long)fixed);
    } @catch (NSException *exception) {
        /* 敲布局失败不影响宿主：下一次系统 resize 仍会自愈 */
    }
}

#pragma mark - V0.2.62：键盘按画布底对齐（AevonKeyFitV262）

/*
 * 用户 Aevon(36) #3：「浮窗内使用键盘时，键盘无法完整显示，要求键盘显示在浮窗外
 * （原生全屏应用的样式）」。
 *
 * 先说结论（诚实）：键盘窗口 `UIRemoteKeyboardWindow` 属于**这个 App 自己的
 * UIWindowScene**，而浮窗呈现的正是那个场景 → 它在物理上只能出现在浮窗里，
 * 任何「挪到浮窗外」都要跨场景，主场景/自建场景两档都做不到。
 *
 * 真正能修的是「不完整」：键盘的 frame 由系统按**真实屏幕**算（y ≈ 932 - 键盘高），
 * 但我们把 UIScreen 报成了画布 430×737 → 键盘落在 y≈596，超出 737 画布的下沿，
 * 用户只看到键盘上半截。这里在键盘窗口 setFrame 那一刻把它按画布底对齐
 * （y = 画布高 - 键盘高），键盘就完整落在浮窗底部、键位全可用。
 *
 * 闸门（防误伤）：
 *   1) 只在屏幕贴合开启（App 正被浮窗承载）时动；
 *   2) 只认类名含 Keyboard 的窗口；
 *   3) 只有该窗口所在场景的高度 ≈ 画布高（±8）才动 —— 场景仍是整屏时
 *      （S1 自建场景档，App 主场景没被改）一个字节都不写。
 */
__attribute__((used)) static const char AevonKeyFitV262Marker[] = "AevonKeyFitV262";

static IMP gAevonKeyFrameOrig;
static BOOL gAevonKeyLogged;

/* V0.2.63：这三个函数定义在下面（画布尺寸推算 + 对位），setFrame: 钩子先用到 ——
 * C99 不支持隐式声明（0.0.52 同款坑），必须先声明。 */
static CGSize AevonAppFloatCanvasSize(void);
static CGFloat AevonAppIsFloatHostedScreenHeight(void);
static CGFloat AevonAppIsFloatHostedScreenWidth(void);
static BOOL AevonAppInShrunkCanvas(void);
static void AevonKeyAuditTick(void);

static BOOL AevonIsKeyboardWindow(UIWindow *window) {
    if (window == nil) { return NO; }
    @try {
        NSString *name = NSStringFromClass([window class]);
        return [name rangeOfString:@"Keyboard"].location != NSNotFound;
    } @catch (NSException *e) { return NO; }
}

static void AevonKeyFrameSwizzled(id self_, SEL _cmd, CGRect frame) {
    CGRect use = frame;
    @try {
        /* V0.2.64（AevonKeyGateV264）：闸门换成「本进程正被渲进一块比真屏矮的画布」。
         * Aevon(38) 日志里本函数**一次都没命中**（整篇只有「已接管」没有「按画布底对齐」）：
         * `AevonAppIsFloatHosted()` 在承载标记抖动的那 150ms 里回 NO，键盘正好在那一刻
         * 出现就整段失效 —— 而用户看到的现象（只露顶部一排）正是键盘按 932 算、被 737 画布裁掉。
         * 新判据只看几何（画布比真屏矮 40pt 以上），与承载标记是否抖无关。 */
        if (AevonAppInShrunkCanvas() && AevonIsKeyboardWindow(self_)) {
            UIWindow *win = (UIWindow *)self_;
            CGFloat canvasH = AevonAppIsFloatHostedScreenHeight();
            CGFloat canvasW = AevonAppIsFloatHostedScreenWidth();
            CGFloat kbH = use.size.height;
            /* V0.2.65（AevonKeyAlignV265）：不再要求 kbH < canvasH。
             * 远程键盘窗口常是**整屏容器**（高 932，键盘视图锚在底部），旧条件直接跳过 →
             * 这一整年都没动过一次。统一按「窗口下沿 = 画布下沿」（origin.y 可为负）。 */
            if (canvasH > 200 && kbH > 40) {
                CGFloat targetY = canvasH - kbH;
                if (fabs(use.origin.y - targetY) > 1.0 || fabs(use.size.width - canvasW) > 1.0) {
                    use.origin.x = 0;
                    use.origin.y = targetY;
                    use.size.width = canvasW;
                    if (!gAevonKeyLogged) {
                        gAevonKeyLogged = YES;
                        AevonAppLog(@"[App侧] 键盘按画布底对齐：%@ → (0,%.0f,%.0f,%.0f)"
                                    @"（画布 %.0fx%.0f，系统给的是整屏坐标 y=%.0f h=%.0f）"
                                    @"→ 键盘完整落在浮窗里"
                                    @"（AevonKeyFitV262 AevonKeyFitV263 AevonKeyGateV264 AevonKeyAlignV265）",
                                    NSStringFromClass([win class]), targetY, canvasW, kbH,
                                    canvasW, canvasH, frame.origin.y, frame.size.height);
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        use = frame;
    }
    if (gAevonKeyFrameOrig != NULL) {
        ((void (*)(id, SEL, CGRect))gAevonKeyFrameOrig)(self_, _cmd, use);
    }
}

/* V0.2.63（AevonKeyFitV263）：浮窗承载期间的画布尺寸。
 * 优先用被接管的 `[UIScreen bounds]`（它就是画布）；万一那一刻没被接管，
 * 按 7:12 竖窗的比例从真实屏宽反推（430 × 12/7 = 737）。 */
static CGSize AevonAppFloatCanvasSize(void) {
    CGSize real = AevonRealScreenSize();
    CGSize hooked = [UIScreen mainScreen].bounds.size;
    if (hooked.width > 100 && hooked.height > 200
        && (real.height < 200 || hooked.height < real.height - 40.0)) {
        return hooked;
    }
    if (real.width > 100) { return CGSizeMake(real.width, floor(real.width * 12.0 / 7.0)); }
    return hooked;
}

static CGFloat AevonAppIsFloatHostedScreenHeight(void) {
    return AevonAppFloatCanvasSize().height;
}

static CGFloat AevonAppIsFloatHostedScreenWidth(void) {
    return AevonAppFloatCanvasSize().width;
}

/* V0.2.64（AevonKeyGateV264）：本进程是不是正被渲进一块「比真屏矮」的画布。
 * 几何优先（被接管的 UIScreen.bounds 就是画布），承载标记只作兜底 ——
 * Aevon(38) 日志里承载标记在多个 App 之间 150ms 一次地翻，靠它当闸门必然漏。 */
/* V0.2.65（AevonKeyAllWindowsV265，用户 Aevon(38) #4 #5.2「键盘依旧只显示一部分」）：
 *
 * 0.2.64 的键盘对位**一次都没执行过** —— Aevon(38) 日志里每次都是
 * 「键盘通知到了但没扫到键盘窗口（画布 430x737，通知高度 191）」。
 * 根因不在闸门，在枚举：`[UIApplication sharedApplication].windows` 从 iOS 13 起
 * 就是废弃接口，**场景化 App 上一律返回空数组**。而键盘窗口在 App 进程里明明存在
 * （同一篇日志的「画面居中：UIInputSetContainerView 高 932」就是它的容器）。
 *
 * 改成三级兜底：私有 `_allWindowsIncludingInternalWindows:onlyVisibleWindows:`
 * → connectedScenes 各场景的 windows → 老的 `windows`。 */
static NSArray<UIWindow *> *AevonAllWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) { return @[]; }
    SEL allSel = NSSelectorFromString(@"_allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    if (allSel != NULL && [app respondsToSelector:allSel]) {
        @try {
            NSArray *(*fn)(id, SEL, BOOL, BOOL) =
                (NSArray *(*)(id, SEL, BOOL, BOOL))(void *)objc_msgSend;
            NSArray *all = fn(app, allSel, YES, NO);
            if ([all isKindOfClass:[NSArray class]] && all.count > 0) {
                return (NSArray<UIWindow *> *)all;
            }
        } @catch (NSException *exception) {
            /* 私有接口变了就退下一级 */
        }
    }
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w != nil && ![result containsObject:w]) { [result addObject:w]; }
        }
    }
    if (result.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in [app windows]) {
            if (w != nil && ![result containsObject:w]) { [result addObject:w]; }
        }
#pragma clang diagnostic pop
    }
    return result;
}

static BOOL AevonAppInShrunkCanvas(void) {
    CGSize real = AevonRealScreenSize();
    if (real.height < 200) { return NO; }
    CGSize hooked = [UIScreen mainScreen].bounds.size;
    /* V0.2.65（AevonKeyGateV265）：只看几何。
     * 0.2.64 的兜底是 `AevonAppIsFloatHosted()`（读偏好 + notify 状态），而它在
     * App 从浮窗转回全屏后会**残留 0.3 秒以上**才翻 —— 那 0.3 秒里键盘会被按 737
     * 摆到全屏 App 的屏幕中间。几何值（被接管的 UIScreen.bounds）没有这个滞后。 */
    return (hooked.height > 200 && hooked.height < real.height - 8.0);
}

/* V0.2.65（AevonKeyAlignV265）：把所有键盘窗口的下沿贴到**画布下沿**。
 *
 * 关键修正（Aevon(38) #4 #5.2 只显示顶部一排）：
 *   远程键盘窗口 `UIRemoteKeyboardWindow` 往往是**整屏容器**（日志里
 *   「UIInputSetContainerView 高 932」就是它内部那层），键盘视图锚在容器底部。
 *   0.2.64 的写法一看到 `h >= 画布高` 就 `continue` 跳过 —— 等于一次都没动。
 *   现在统一按「窗口下沿 = 画布下沿」算，h 比画布高时 origin.y 自然为负，
 *   正好把锚在底部的键盘顶进画布可视区。
 *
 * 返回找到的键盘窗口数（-1 = 闸门挡住/画布无效）。 */
static NSInteger AevonKeyAlignWindows(NSString *tag, BOOL verbose) {
    if (!AevonAppInShrunkCanvas()) { return -1; }
    CGSize canvas = AevonAppFloatCanvasSize();
    if (canvas.height < 200) { return -1; }
    NSArray<UIWindow *> *windows = AevonAllWindows();
    NSInteger found = 0;
    NSInteger fixed = 0;
    for (UIWindow *w in windows) {
        if (![w isKindOfClass:[UIWindow class]]) { continue; }
        if (!AevonIsKeyboardWindow(w)) { continue; }
        found += 1;
        CGFloat h = w.bounds.size.height;
        if (h < 40) { continue; }
        CGRect target = CGRectMake(0, canvas.height - h, canvas.width, h);
        CGRect now = w.frame;
        if (fabs(CGRectGetMinY(now) - CGRectGetMinY(target)) < 1.0
            && fabs(now.size.height - target.size.height) < 1.0
            && fabs(now.size.width - target.size.width) < 1.0) {
            continue;
        }
        w.frame = target;
        [w setNeedsLayout];
        [w layoutIfNeeded];
        fixed += 1;
        if (verbose && fixed <= 4) {
            AevonAppLog(@"[App侧] 键盘对位（%@）：%@ %@ → %@（画布 %.0fx%.0f，键盘窗口高 %.0f）"
                        @"（AevonKeyFitV263 AevonKeyAuditV264 AevonKeyAlignV265）",
                        tag, NSStringFromClass([w class]), NSStringFromCGRect(now),
                        NSStringFromCGRect(target), canvas.width, canvas.height, h);
        }
    }
    if (found == 0 && verbose) {
        AevonAppLog(@"[App侧] 键盘对位（%@）：扫了 %lu 个窗口，没有键盘窗口"
                    @"（画布 %.0fx%.0f）（AevonKeyAlignV265）",
                    tag, (unsigned long)windows.count, canvas.width, canvas.height);
    }
    return found;
}

static void AevonKeyAuditTick(void);

/* V0.2.67（AevonKbHideV267）：前向声明 —— 定义在文件后部（AevonKeyboardVisible 之后），
 * 而第一个调用点（AevonKeyRepositionNow）在前面，C 必须先声明（0.2.62 实锤过）。 */
static void AevonKbVisSync(void);

static void AevonKeyRepositionNow(NSNotification *note) {
    /* V0.2.67（AevonKbHideV267）：键盘显一收一都从这里过 —— 顺手把「键盘在屏」
     * 状态用 Darwin 通知广播给 SB（SB 收到后把把手触发条临时藏掉，
     * 防止它压在键盘右列 p/l/⌫ 上）。 */
    AevonKbVisSync();
    @try {
        NSInteger found = AevonKeyAlignWindows(@"收到键盘通知", YES);
        if (found <= 0) { return; }
        /* 审计：0.15s 一拍共 20 拍（3 秒）。系统有时候会把窗口又摆回去，
         * 或者键盘窗口比通知晚建出来 —— 每一拍补一次，稳定后自然幂等。 */
        for (int i = 1; i <= 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.15 * i * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AevonKeyAuditTick();
            });
        }
    } @catch (NSException *exception) {
        AevonAppLog(@"[App侧] 键盘通知对位异常：%@（不影响宿主）（AevonKeyFitV263）",
                    exception.reason ?: @"未知");
    }
}

static void AevonKeyAuditTick(void) {
    @try {
        AevonKeyAlignWindows(@"审计补位", NO);
    } @catch (NSException *exception) {
        /* 审计静默失败：不影响宿主 */
    }
}

/* ── V0.2.63（AevonCenterContentV263）：把画面中心拉回浮窗中心 ───────────────────
 * 用户 Aevon(37) #1：「抖音真重排一秒后内容上移、下面黑。能不能让抖音画面的中心始终
 * 保持在悬浮窗的中心」。
 *
 * 前面两版都在 SB 侧改画布尺寸（S2 主场景改画布），尺寸是对的（日志「内容宿主
 * 430x737 已贴合画布」），可画面还是整体偏上留一条黑 —— 说明抖音自己的**根视图**仍然
 * 按整屏高度（932）排好了内部坐标，场景变窄之后它只裁不重排：可见区永远是那 932 的
 * 顶上 737，画面中心自然不在窗口中心。
 *
 * 这一版换到 App 进程里做**视觉对中**：浮窗承载期间看一眼主窗口的根视图，
 * 如果它比窗口还高（说明内部仍按整屏排版），就把根视图整体平移
 * (窗口高 - 根视图高)/2 —— 屏幕上看就是「画面中心 = 窗口中心」。
 * 只改 transform（不碰约束、不碰子视图坐标），关窗立刻还原；
 * 位移上限 240pt（防止某个 App 的超长滚动视图被误判后甩飞）。
 * 纪律：整个方法包在 @try 里，任何异常都只记日志（圆盘 / 浮窗是天天用的入口）。
 */
__attribute__((used)) static const char AevonCenterContentV263Marker[] = "AevonCenterContentV263";

static BOOL gAevonCenterApplied = NO;
static __weak UIView *gAevonCenterTarget = nil;

/* 在窗口里找「比窗口高一大截」的那一层（浅层优先，最多走 3 层）。
 * 抖音这类 App 的形态是：根视图 = 窗口高，里面某一层容器仍是整屏 932 → 那一层就是要对中的目标。 */
static UIView *AevonFindOversizeView(UIView *root, CGFloat windowH) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (int depth = 0; depth < 3 && queue.count > 0; depth++) {
        NSUInteger count = queue.count;
        UIView *best = nil;
        for (NSUInteger i = 0; i < count; i++) {
            UIView *view = queue[i];
            CGFloat h = view.bounds.size.height;
            if (view != root && h > windowH + 40.0 && h <= windowH + 240.0) {
                if (best == nil || h > best.bounds.size.height) { best = view; }
            }
            [queue addObjectsFromArray:view.subviews];
        }
        if (best != nil) { return best; }
        [queue removeObjectsInRange:NSMakeRange(0, count)];
    }
    return nil;
}

static void AevonCenterContentRefresh(BOOL floatHosted) {
    @try {
        UIWindow *main = nil;
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (AevonIsKeyboardWindow(w)) { continue; }
                if (main == nil || w.bounds.size.height > main.bounds.size.height) { main = w; }
            }
        }
        UIView *root = main.rootViewController.view;
        if (main == nil || root == nil) { return; }
        if (!floatHosted) {
            if (gAevonCenterApplied) {
                gAevonCenterApplied = NO;
                gAevonCenterTarget.transform = CGAffineTransformIdentity;
                gAevonCenterTarget = nil;
                AevonAppLog(@"[App侧] 关窗 → 画面位移已还原（AevonCenterContentV263）");
            }
            return;
        }
        /* V0.2.64（AevonCenterCanvasV264）：口径换成**画布高**，不再用窗口高。
         * Aevon(38) 日志证明这条从来没跑过（整篇 0 条「画面居中」）：当 App 的窗口
         * 仍是 932 时 `windowH = 932`，BFS 找「比窗口高 40–240」的目标永远是 nil →
         * 静默返回，画面还是偏上。现在两档都覆盖：
         *   ① 窗口本身比画布高（App 没重排）→ 直接平移根视图；
         *   ② 窗口已经贴合画布、内部还有一层按整屏排版 → 平移那一层。 */
        CGFloat canvasH = AevonAppIsFloatHostedScreenHeight();
        if (canvasH < 300 || canvasH >= 8000) { canvasH = 0; }
        if (canvasH < 300) {
            /* 兜底：按 7:12 竖窗比例从真屏宽反推（430 × 12/7 = 737） */
            CGSize real = AevonRealScreenSize();
            if (real.width > 100) { canvasH = floor(real.width * 12.0 / 7.0); }
        }
        CGFloat winH = main.bounds.size.height;
        if (canvasH < 300 || winH < 200) { return; }
        UIView *target = nil;
        CGFloat diff = 0;
        if (winH > canvasH + 8.0 && winH - canvasH <= 400.0) {
            target = root;
            diff = winH - canvasH;
        } else {
            target = AevonFindOversizeView(root, canvasH);
            if (target != nil) { diff = target.bounds.size.height - canvasH; }
        }
        if (target == nil || diff <= 8.0) {
            if (gAevonCenterApplied) {
                gAevonCenterApplied = NO;
                gAevonCenterTarget.transform = CGAffineTransformIdentity;
                gAevonCenterTarget = nil;
                AevonAppLog(@"[App侧] 各层尺寸都已贴合画布 → 撤掉画面位移"
                            @"（AevonCenterContentV263 AevonCenterCanvasV264）");
            }
            return;
        }
        /* V0.2.66（AevonTopAlignV266，用户 Aevon(39) #8「悬浮窗打开设置时底部有黑屏
         * 大约 10%，系统应用不会自动修复」）：居中（上移 diff/2）改成**顶对齐**。
         * 真因：没重排的 App 内容高 932 > 画布 737，上移 97.5pt 后内容占
         * -97.5..834.5，而窗口底部到 834.5 之间没有内容像素 = 底部一条黑
         * （约 97.5/737 ≈ 13%）。顶对齐（位移 0）时内容从 0 画到 932，窗口
         * 0..737 全程有像素、超出部分被画布自然裁掉 —— 无缝，只是底部内容看不到。
         * 能重排的 App（内容收到 737）走 diff <= 8 分支照常不动，无影响。 */
        CGFloat shift = 0.0;
        if (gAevonCenterApplied && gAevonCenterTarget == target
            && fabs(gAevonCenterTarget.transform.ty - shift) < 0.5) { return; }
        gAevonCenterApplied = YES;
        gAevonCenterTarget = target;
        target.transform = CGAffineTransformMakeTranslation(0, shift);
        AevonAppLog(@"[App侧] 画面顶对齐：%@ 高 %.0f 超出画布 %.0f（窗口 %.0f）"
                    @"→ 位移归零，内容从顶部铺起、超出部分由画布裁掉，底部不再露黑"
                    @"（AevonCenterContentV263 AevonTopAlignV266）",
                    NSStringFromClass([target class]), target.bounds.size.height,
                    canvasH, winH);
    } @catch (NSException *exception) {
        AevonAppLog(@"[App侧] 画面居中失败：%@（不影响宿主）（AevonCenterContentV263）",
                    exception.reason ?: @"未知");
    }
}

/* V0.2.63 标记：ObjC 里的中文日志串会被编成 UTF-16（strings 查不到），
 * 所以每个标记单独放一条纯 ASCII 的 used 数组，保证一定出现在编译产物里。 */
__attribute__((used)) static const char AevonKeyFitV263Marker[] = "AevonKeyFitV263";
__attribute__((used)) static const char AevonKeyboardVisibleFixV263Marker[] = "AevonKeyboardVisibleFixV263";
__attribute__((used)) static const char AevonGripSwallowFixV263Marker[] = "AevonGripSwallowFixV263";
/* V0.2.64 的同款纪律：带中文的 @"…" 会编成 UTF-16，strings 查不到 —— 标记必须单独放纯 ASCII 常量 */
__attribute__((used)) static const char AevonCenterCanvasV264Marker[] = "AevonCenterCanvasV264";
__attribute__((used)) static const char AevonKeyGateV264Marker[] = "AevonKeyGateV264";
__attribute__((used)) static const char AevonKeyAuditV264Marker[] = "AevonKeyAuditV264";
__attribute__((used)) static const char AevonFitDebounceV264Marker[] = "AevonFitDebounceV264";
/* V0.2.65 同款纪律：纯 ASCII 常量，保证 strings 一定查得到 */
__attribute__((used)) static const char AevonEdgeShieldV265Marker[] = "AevonEdgeShieldV265";
__attribute__((used)) static const char AevonKeyAllWindowsV265Marker[] = "AevonKeyAllWindowsV265";
__attribute__((used)) static const char AevonKeyAlignV265Marker[] = "AevonKeyAlignV265";
__attribute__((used)) static const char AevonNoCapsFileV265Marker[] = "AevonNoCapsFileV265";
__attribute__((used)) static const char AevonFrameFileV266Marker[] = "AevonFrameFileV266";
__attribute__((used)) static const char AevonTopAlignV266Marker[] = "AevonTopAlignV266";
__attribute__((used)) static const char AevonShieldFSV267Marker[] = "AevonShieldFSV267";
__attribute__((used)) static const char AevonKbHideV267Marker[] = "AevonKbHideV267";
__attribute__((used)) static const char AevonSwallowOneV267Marker[] = "AevonSwallowOneV267";
/* V0.2.68（AevonCanvasBandV268）：承载模式画布边缘带吞咽 —— 标记必须放纯 ASCII
 * used 常量（ObjC 中文字符串编 UTF-16，strings 搜不到，0.2.61 老雷区）。 */
__attribute__((used)) static const char AevonCanvasBandV268Marker[] = "AevonCanvasBandV268";

static void AevonKeyFitInstall(void) {
    @try {
        Class kb = NSClassFromString(@"UIRemoteKeyboardWindow");
        if (kb == Nil) {
            AevonAppLog(@"[App侧] 本系统没有 UIRemoteKeyboardWindow，键盘对齐跳过（AevonKeyFitV262）");
            return;
        }
        Method m = class_getInstanceMethod(kb, @selector(setFrame:));
        if (m == NULL) {
            AevonAppLog(@"[App侧] UIRemoteKeyboardWindow 没有 -setFrame:，键盘对齐跳过（AevonKeyFitV262）");
            return;
        }
        const char *types = method_getTypeEncoding(m);
        if (types == NULL || types[0] != 'v' || strstr(types, "{CGRect=") == NULL) {
            AevonAppLog(@"[App侧] -setFrame: 编码不符（%s），键盘对齐不装（fail-closed）（AevonKeyFitV262）",
                        types ?: "?");
            return;
        }
        gAevonKeyFrameOrig = method_getImplementation(m);
        method_setImplementation(m, (IMP)AevonKeyFrameSwizzled);
        AevonAppLog(@"[App侧] 已接管 -[UIRemoteKeyboardWindow setFrame:]：键盘按画布底对齐，"
                    @"不再只露出上半截（AevonKeyFitV262）");
        /* V0.2.63（AevonKeyFitV263）：再加一条通知驱动的补正 —— setFrame: 偶尔只改内部
         * layer、不改窗口；键盘「显示不全」的另一半原因就在这里。 */
        static BOOL observersInstalled = NO;
        if (!observersInstalled) {
            observersInstalled = YES;
            void (^handler)(NSNotification *) = ^(NSNotification *note) {
                AevonKeyRepositionNow(note);
            };
            [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:handler];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:handler];
            AevonAppLog(@"[App侧] 键盘通知监听已装（UIKeyboardWillChangeFrame / DidShow）"
                        @"：键盘每次出现都按画布底对一次位（AevonKeyFitV263）");
        }
    } @catch (NSException *exception) {
        AevonAppLog(@"[App侧] 键盘对齐安装失败：%@（AevonKeyFitV262）", exception.reason ?: @"未知");
    }
}

/* 前向声明（V0.2.59）：ScreenFitRefresh 的 0.5s 轮询兜底要调停靠交互刷新，
 * 定义在本文件更后面 —— C99 不支持隐式声明（0.2.52 同款坑，编译期才暴露）。
 * V0.2.63：把手占用刷新同样在轮询里兜底一次（通知丢了也不会卡在无交互态）。 */
static void AevonDockInteractionRefresh(void);
static void AevonGripBusyRefresh(BOOL fromNotify);
static void AevonCenterContentRefresh(BOOL floatHosted);

static void AevonScreenFitRefresh(void) {
    if (gAevonScreenFitRefreshing) { return; }
    gAevonScreenFitRefreshing = YES;
    BOOL flipped = NO;
    BOOL nowOn = gAevonScreenFitOn;
    @try {
        BOOL on = AevonAppIsFloatHosted();
        /* V0.2.64（AevonFitDebounceV264）：承载标记会**抖**。
         * Aevon(38) 日志 12:20:32–12:20:39 之间，「屏幕贴合 开/关」在 Preferences /
         * Sileo / BatteryInfo 之间 150ms 一轮地翻了十几遍 —— 用户每从圆盘切一个 App，
         * SB 就重设一次承载标记。每翻一次我们就 nudge 一次窗口重排、甚至把窗口拉回整屏，
         * 于是「布局按 737、窗口按 932」的中间态被反复制造出来 = 用户说的第二次黑屏。
         * 现在新状态必须先稳定 0.30 秒才承认（打开浮窗时 SB 自己会先把画布改好，
         * UIScreen 这一层晚 0.3 秒不影响观感）。 */
        CFTimeInterval now = CACurrentMediaTime();
        if (on == gAevonScreenFitOn) {
            gAevonScreenFitPendingOn = on;
            gAevonScreenFitPendingSince = 0;
        } else {
            if (gAevonScreenFitPendingOn != on || gAevonScreenFitPendingSince <= 0) {
                gAevonScreenFitPendingOn = on;
                gAevonScreenFitPendingSince = now;
                gAevonScreenFitCheckedAt = now;
                gAevonScreenFitRefreshing = NO;
                return;   /* 抖动期：这一拍不认，等它稳 */
            }
            if (now - gAevonScreenFitPendingSince >= 0.30) {
                gAevonScreenFitOn = on;
                gAevonScreenFitPendingSince = 0;
                flipped = YES;
            }
        }
        nowOn = gAevonScreenFitOn;
        if (flipped || !gAevonScreenFitLogged) {
            gAevonScreenFitLogged = YES;
            AevonAppLog(@"屏幕贴合：%@（AevonAppScreenFitV249 AevonFitDebounceV264）",
                        nowOn ? @"开 —— 本 App 正被浮窗承载，UIScreen 改报画布尺寸"
                              : @"关 —— 按真实屏幕报告");
        }
        gAevonScreenFitCheckedAt = CACurrentMediaTime();
    } @catch (NSException *exception) {
        gAevonScreenFitOn = NO;
    }
    gAevonScreenFitRefreshing = NO;
    if (flipped) { AevonScreenFitNudgeLayout(nowOn); }
    /* V0.2.63（AevonCenterContentV263）：开窗那一下先对一次中，再在 0.4 / 0.9 / 1.5 秒
     * 各复查一次 —— 用户 Aevon(37) #1 的现象是「真重排成立，一秒后才上移」，说明 App
     * 是**晚一步**才把内部尺寸改回整屏的，一开局对中不够，要跟一段。 */
    if (flipped) {
        AevonCenterContentRefresh(nowOn);
        if (nowOn) {
            for (NSNumber *delay in @[@0.4, @0.9, @1.5]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    AevonCenterContentRefresh(AevonAppIsFloatHosted());
                });
            }
        }
    }
    /* V0.2.59（AevonDockStageV259）：0.5s 轮询兜底刷新停靠交互（事件驱动为主）。 */
    AevonDockInteractionRefresh();
    /* V0.2.63（AevonGripBusyV263）：把手占用同样轮询兜底（只做撤销，不会误关）。 */
    AevonGripBusyRefresh(NO);
}

static CGRect AevonScreenBoundsFit(id self_, SEL _cmd) {
    if (gAevonScreenBoundsOrigIMP == NULL) { return CGRectZero; }
    CGRect real = ((CGRect (*)(id, SEL))gAevonScreenBoundsOrigIMP)(self_, _cmd);
    @try {
        CFTimeInterval now = CACurrentMediaTime();
        /* V0.2.64：采样间隔 0.5 → 0.20 秒，配合 0.30 秒去抖（否则一次翻转要等 0.5~0.8s） */
        if (now - gAevonScreenFitCheckedAt >= 0.20) { AevonScreenFitRefresh(); }
        if (!gAevonScreenFitOn) { return real; }
        if (real.size.width < 2) { return real; }
        CGFloat width = floor(real.size.width);
        CGFloat height = floor(width * 12.0 / 7.0);
        return CGRectMake(real.origin.x, real.origin.y, width, height);
    } @catch (NSException *exception) {
        return real;
    }
}

/* ── V0.2.59（AevonDockStageV259）：停靠期间把主窗口交互关掉 ─────────────────
 *
 * 问题（用户 Aevon(33) #2）：点停靠小窗装回主窗时，小窗里的 App 内容**也被点了一下**
 * —— backboardd 双投（SB + 直投 App），SB 侧 `setContentInteraction(false)` 只断了
 * presenter 转发路径，直投 App 的那份照落在 App 自己的主窗口上 = 内容点击。
 *
 * 判定：SB 侧把当前停靠集合的 bundleID 散列写在 `com.aevon.dockstage0..4`
 * （notify state，沙盒必可读），本进程算自己的散列比对 —— 命中 = 正在停靠，
 * 把本进程所有 UIWindow 的 isUserInteractionEnabled 关掉：直投触摸被 UIKit
 * 整根丢弃（无 began 无 ended，零孤儿帧），画面照常渲染。
 * fail-closed：读不到（全部 state=0）= 不在停靠 = 恢复交互，绝不卡死在无交互态。
 * 保险丝：didBecomeActive（停靠中的 App 被全屏拉起，即便通知丢失也必然解锁）；
 * 0.5s 屏幕贴合轮询顺带兜底刷新一次。 */
__attribute__((used)) static const char AevonDockStageV259Marker[] = "AevonDockStageV259";
__attribute__((used)) static const char AevonDockFuseV259Marker[] = "AevonDockFuseV259";

static int gAevonDockStageTokens[5] = {-1, -1, -1, -1, -1};
static int gAevonDockStageNotifyToken = -1;
static int gAevonGripBusyToken = -1;
static BOOL gAevonDockStageOnce = NO;
static BOOL gAevonDockActive = NO;
/* V0.2.63（AevonGripBusyV263）：手指正压在把手上 → 本进程窗口交互临时关闭。 */
static BOOL gAevonGripBusy = NO;
static BOOL gAevonGripBusyDirty = NO;
static uint32_t gAevonGripBusyGeneration = 0;
static void AevonDockInteractionRefresh(void);

static BOOL AevonAppDockCheck(void) {
    if (!gAevonDockStageOnce) {
        gAevonDockStageOnce = YES;
        for (int i = 0; i < 5; i++) {
            NSString *name = [NSString stringWithFormat:@"com.aevon.dockstage%d", i];
            notify_register_check(name.UTF8String, &gAevonDockStageTokens[i]);
        }
    }
    uint32_t mine = AevonAppFloatStageHash(gAevonAppBundleID);
    if (mine == 0) { return NO; }
    for (int i = 0; i < 5; i++) {
        uint64_t state = 0;
        if (gAevonDockStageTokens[i] >= 0 &&
            notify_get_state(gAevonDockStageTokens[i], &state) == NOTIFY_STATUS_OK) {
            if (state == (uint64_t)mine) { return YES; }
        }
    }
    return NO;
}

static void AevonDockInteractionRefresh(void) {
    @try {
        BOOL docked = AevonAppDockCheck();
        if (docked == gAevonDockActive && !gAevonGripBusy && !gAevonGripBusyDirty) { return; }
        gAevonGripBusyDirty = NO;
        gAevonDockActive = docked;
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { return; }
        NSInteger touched = 0;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                // V0.2.63（AevonGripBusyV263）：把手占用期同样关掉交互
                // （手指压在把手上时，App 不该收到任何直投触摸）。
                BOOL want = (!docked && !gAevonGripBusy);
                if (window.userInteractionEnabled != want) {
                    window.userInteractionEnabled = want;
                    touched += 1;
                }
            }
        }
        AevonAppLog(@"停靠交互：%@（%ld 个窗口 userInteractionEnabled=%@）"
                    @"（AevonDockStageV259）",
                    docked ? @"本 App 进入停靠 → 主窗口交互关闭（拦 backboardd 直投触摸，"
                            @"点停靠小窗不再触发内容点击）"
                           : @"本 App 离开停靠 → 主窗口交互恢复",
                    (long)touched,
                    docked ? @"NO" : @"YES");
    } @catch (NSException *exception) {
        /* 刷新失败保持现状：下一次通知 / 轮询会再来 */
    }
}

/* V0.2.63（AevonGripBusyV263）：SB 说「手指在把手上」→ 本进程关交互。
 *
 * 为什么不再用坐标判定：0.2.61 / 0.2.62 两版都在 App 侧按落点矩形判，
 * Aevon(36) / Aevon(37) 两篇日志里「把手区落点」都是 **0 条** —— 说明那条路
 * 在真机上根本命中不了（App 拿到的点、窗口坐标系、被接管的 UIScreen，任何
 * 一环偏一点就永远判不中）。改成「SB 说压住了 → 我整体不接触摸」，与几何无关。
 *
 * 闸门（防误伤）：只在本 App 占满整屏、且没有被浮窗承载时才关交互 ——
 * 浮窗里的 App 右缘没有把手，关了只会让浮窗内容点不动。
 * fail-open：读不到「占用」态一律恢复交互；0.6 秒硬超时兜底（抬手包丢了也不会卡死）。
 */
static void AevonGripBusyRefresh(BOOL fromNotify) {
    @try {
        if (gAevonGripBusyToken < 0) { return; }
        uint64_t state = 0;
        BOOL busy = NO;
        if (notify_get_state(gAevonGripBusyToken, &state) == NOTIFY_STATUS_OK) {
            busy = (state != 0);
        }
        if (busy) {
            /* 只有全屏 App 才需要关：浮窗承载中（画布尺寸）把手不在这个进程的界面上。 */
            if (AevonAppIsFloatHosted()) { return; }
            CGSize real = AevonRealScreenSize();
            CGFloat tallest = 0;
            @try {
                for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                        if (AevonIsKeyboardWindow(w)) { continue; }
                        tallest = MAX(tallest, w.bounds.size.height);
                    }
                }
            } @catch (NSException *e) { tallest = 0; }
            if (real.height > 200 && tallest < real.height - 60.0) { return; }
            gAevonGripBusyGeneration += 1;
            uint32_t generation = gAevonGripBusyGeneration;
            if (!gAevonGripBusy) {
                gAevonGripBusy = YES;
                gAevonGripBusyDirty = YES;
                AevonDockInteractionRefresh();
                AevonAppLog(@"[App侧] 把手占用 → 本进程窗口交互临时关闭（UIKit 会取消这根手指，"
                            @"App 内的左滑 / 长按不会开始）（AevonGripBusyV263）");
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != gAevonGripBusyGeneration) { return; }
                if (!gAevonGripBusy) { return; }
                gAevonGripBusy = NO;
                gAevonGripBusyDirty = YES;
                AevonDockInteractionRefresh();
                AevonAppLog(@"[App侧] 把手占用满 0.6s 未见抬手 → 自行恢复交互（fail-open）"
                            @"（AevonGripBusyV263）");
            });
            return;
        }
        if (gAevonGripBusy) {
            gAevonGripBusy = NO;
            gAevonGripBusyDirty = YES;
            AevonDockInteractionRefresh();
            AevonAppLog(@"[App侧] 把手占用结束 → 交互恢复（%@）（AevonGripBusyV263）",
                        fromNotify ? @"来自 SB 通知" : @"轮询兜底");
        }
    } @catch (NSException *exception) {
        gAevonGripBusy = NO;
        gAevonGripBusyDirty = YES;
        AevonDockInteractionRefresh();
    }
}

static void AevonDockInteractionInstall(void) {
    @try {
        if ([gAevonAppBundleID isEqualToString:@"com.apple.springboard"]) { return; }
        if (gAevonDockStageNotifyToken < 0) {
            notify_register_dispatch("com.aevon.dockstage", &gAevonDockStageNotifyToken,
                                     dispatch_get_main_queue(), ^(int token) {
                AevonDockInteractionRefresh();
            });
        }
        /* V0.2.63（AevonGripBusyV263，用户 Aevon(37) #7）：SB 侧「手指落在把手上」的广播
         * —— 收到就把本进程窗口交互关掉（UIKit 会取消这根手指，App 内的左滑 / 长按
         * 来不及开始），抬手或 0.6 秒后恢复。这条通道与坐标无关，必达。 */
        if (gAevonGripBusyToken < 0) {
            notify_register_check("com.aevon.gripbusy", &gAevonGripBusyToken);
        }
        static int gripNotifyToken = -1;
        if (gripNotifyToken < 0) {
            notify_register_dispatch("com.aevon.gripbusy", &gripNotifyToken,
                                     dispatch_get_main_queue(), ^(int token) {
                AevonGripBusyRefresh(YES);
            });
        }
        /* 保险丝：回前台强制重判（停靠中的 App 被全屏拉起时，即使 SB 侧清位通知
         * 丢了，这一步也必然把交互恢复回来 —— 绝不让全屏 App 变成「点不动」）。 */
        [[NSNotificationCenter defaultCenter] addObserverForName:
         UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:nil
                                               usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AevonDockInteractionRefresh();
            });
        }];
    } @catch (NSException *exception) {
        AevonAppLog(@"停靠交互：安装失败 %@（不影响宿主）（AevonDockStageFailV259）",
                    exception.reason ?: @"未知");
    }
}

static void AevonScreenFitInstall(void) {
    if ([gAevonAppBundleID isEqualToString:@"com.apple.springboard"]) { return; }
    @try {
        UIScreen *screen = [UIScreen mainScreen];
        Class cls = screen != nil ? object_getClass(screen) : [UIScreen class];
        SEL sel = @selector(bounds);
        Method m = class_getInstanceMethod(cls, sel);
        if (m == NULL) {
            AevonAppLog(@"屏幕贴合：%@ 没有 -bounds，跳过（AevonAppScreenFitV249）",
                        NSStringFromClass(cls) ?: @"?");
            return;
        }
        gAevonScreenBoundsOrigIMP = method_getImplementation(m);
        class_replaceMethod(cls, sel, (IMP)AevonScreenBoundsFit, method_getTypeEncoding(m));
        AevonAppLog(@"屏幕贴合：已接管 %@ -bounds（浮窗承载期间 UIScreen 报「屏宽 × 屏宽÷(7/12)」，"
                    @"与画布同比例；关窗即恢复真实值）（AevonAppScreenFitV249）",
                    NSStringFromClass(cls) ?: @"?");
        /* V0.2.50（AevonAppFitRelayoutV250）：把「0.5 秒轮询」升级成「事件驱动 + 轮询兜底」。
         * 共享内存 com.aevon.floatstage 一变（开窗 / 关窗 / 换 App），主线程立刻重算一次 ——
         * 关窗那一刻的顺序因此变成：信号清 → 本进程 10ms 内把 UIScreen 改回 932 并重排 →
         * SB 侧再写一次整屏画布。少了这个事件，本进程要等最多 0.5 秒才知道「门已经关了」，
         * 而关窗流程 1 秒就结束了，于是永远停在「按 737 排版」的残局里（第 1 条的黑屏）。 */
        static int fitNotifyToken = -1;
        if (fitNotifyToken < 0) {
            notify_register_dispatch("com.aevon.floatstage", &fitNotifyToken,
                                     dispatch_get_main_queue(), ^(int token) {
                AevonScreenFitRefresh();
            });
        }
        /* V0.2.59（AevonDockStageV259）：停靠交互拦截（事件驱动 + 保险丝）。 */
        AevonDockInteractionInstall();
        /* V0.2.62（AevonKeyFitV262）：键盘按画布底对齐（只在被浮窗承载时生效）。 */
        AevonKeyFitInstall();
    } @catch (NSException *exception) {
        AevonAppLog(@"屏幕贴合：接管失败 %@（不影响宿主，按真实屏幕走）（AevonAppScreenFitFailV249）",
                    exception.reason ?: @"未知");
    }
}

#pragma mark - V0.2.61：把手滑动不再带着 App 内操作（AevonGripSwallowV261）

/*
 * 用户 Aevon(35) #8：「全屏时滑动触发条会带着 App 内的操作（例如 QQ 的左滑删除
 * 聊天记录）」。
 *
 * 根因不是我们吞得不够狠，而是**双投**：backboardd 把同一根手指同时投给 SpringBoard
 * 和前台 App 进程。0.2.60 在 SB 侧对把手滑动「只观察不吞」（铁律：不在别人的触摸上
 * 做吞咽），于是 App 那一份原封不动地进去当了一次左滑 —— QQ 就删了聊天记录。
 * 唯一能拦住 App 那一份的地方，只有 App 自己的进程。
 *
 * 做法：拦 `-[UIApplication sendEvent:]`，把**落点在把手命中区**的触摸整根丢掉
 * （began 就不投递，App 永远没见过它），绝不中途改判 —— 铁律「began 已投递 UIKit
 * 的触摸不许再改吞」仍然成立，因为这里连 began 都不给。
 *
 * 命中区与把手视图严格同源：右缘 5pt 竖条 + 向内 40pt、上下各 14pt；
 * 位置 = 屏高 ×(1 - GripY/100)，长度 = GripLen（夹 36~120）。参数每 2 秒最多读一次。
 *
 * 两条安全闸（这条 hook 跑在**别人 App 的进程里**，误伤比不生效更糟）：
 *   · 只在 App 占满整屏时生效；进浮窗后 window 高度 = 画布 737，一律不吞；
 *   · 键盘在屏上时不吞 —— 否则打字时键盘右列（p / l / ⌫）会有时候按不出来。
 */

static IMP gAevonSendEventOrig;
static NSMutableSet *gAevonSwallowedTouches;
static CFTimeInterval gAevonGripCacheAt;
static CGRect gAevonGripRect;
static CGSize gAevonRealScreen;
static BOOL gAevonGripCached;

/* 纯 ASCII 的 used 数组：CI 用 strings 查标记，而 @"…（AevonGripSwallowV261）" 这种
 * 带中文的字面量在 ObjC 里会被编成 UTF-16 存进 __ustring —— strings 一个字节都搜不到
 * （0.2.61 第一次构建就是栽在这里）。本文件其它版本的标记同样靠这种数组兜底。 */
__attribute__((used)) static const char AevonGripSwallowV261Marker[] = "AevonGripSwallowV261";

/* 真·屏幕尺寸：直接走**被接管前的** -[UIScreen bounds] 原实现。
 * 不能用当前 [UIScreen bounds] —— 它在本进程里被 AevonAppScreenFitV249 接管过，
 * App 进浮窗后会报成画布 430×737，把手命中区就会算错位；
 * 也不能去动像素级尺寸（0.2.49 的硬规矩：只许改 bounds 这一个方法）。 */
static CGSize AevonRealScreenSize(void) {
    UIScreen *screen = [UIScreen mainScreen];
    if (gAevonScreenBoundsOrigIMP != NULL) {
        CGRect real = ((CGRect (*)(id, SEL))gAevonScreenBoundsOrigIMP)(screen, @selector(bounds));
        if (real.size.width > 10 && real.size.height > 10) { return real.size; }
    }
    return screen.bounds.size;
}

/* 键盘在屏上？（横幅、输入法候选视图都算）
 * 必须挡掉：把手的竖直带子会压在键盘右列上（默认位置 30% = 屏高 70% 处，
 * 92pt 高、右缘 45pt 宽），如果照吞，用户在别的 App 里打字会「偶尔按不出 p / l / ⌫」。
 * 键盘窗口扫一遍很便宜，而且只在 began 这一拍查。 */
/* V0.2.67（AevonKbHideV267，用户 Aevon(40) #3「全屏 App 开键盘时键盘右侧和触发条
 * 冲突」）：键盘在屏状态一变，就用 Darwin 通知广播给 SB —— SB 收到后把把手触发条
 * 整条临时屏蔽（防压键盘右列 p/l/⌫），收起后恢复。Darwin 通知不带载荷，
 * 用 on/off 两个通知名表达状态。 */
static BOOL gAevonKbVisLast = NO;
static BOOL AevonKeyboardVisible(void);   /* V0.2.67：前向声明（定义在本函数之后） */
static void AevonKbVisSync(void) {
    BOOL vis = NO;
    @try { vis = AevonKeyboardVisible(); } @catch (NSException *e) { vis = NO; }
    if (vis == gAevonKbVisLast) { return; }
    gAevonKbVisLast = vis;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        vis ? CFSTR("com.aevon.kbvis.on") : CFSTR("com.aevon.kbvis.off"),
        NULL, NULL, TRUE);
}

static BOOL AevonKeyboardVisible(void) {
    NSArray *windows = nil;
    /* -[UIApplication windows] 在 iOS 15+ 标了 deprecated，而本工程开着 -Werror：
     * UIWindowScene.windows 只覆盖「当前场景」，键盘窗口（UIRemoteKeyboardWindow）
     * 未必挂在那个场景下 —— 为了不漏判，这里仍旧走全量窗口表，只把这条警告就地压掉。 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    @try { windows = [[UIApplication sharedApplication] windows]; } @catch (NSException *e) { windows = nil; }
#pragma clang diagnostic pop
    for (UIWindow *w in windows) {
        if (w == nil || w.hidden || w.alpha < 0.01) { continue; }
        NSString *name = NSStringFromClass([w class]) ?: @"";
        /* V0.2.63（AevonKeyboardVisibleFixV263）：原来把 `TextEffects` 也算键盘 ——
         * 但 `UITextEffectsWindow` 在**每个 App 里常驻**（没键盘时也在），于是
         * `AevonKeyboardVisible()` 恒为 YES，把「把手吞咽」整条链闸死了。
         * 现在只认真正的键盘窗口，并且要求它确有高度（> 80pt）。 */
        if ([name rangeOfString:@"Keyboard"].location == NSNotFound) { continue; }
        if (w.bounds.size.height > 80.0 && w.bounds.size.width > 100.0) { return YES; }
    }
    return NO;
}

static void AevonGripRefreshCache(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (gAevonGripCached && now - gAevonGripCacheAt < 2.0) { return; }
    gAevonGripCacheAt = now;
    gAevonGripCached = YES;
    gAevonGripRect = CGRectZero;
    gAevonRealScreen = AevonRealScreenSize();
    CFPropertyListRef enabled = CFPreferencesCopyAppValue(CFSTR("RingGripEnabled"), CFSTR("com.Aevon"));
    BOOL on = YES;
    if (enabled != NULL) {
        if (CFGetTypeID(enabled) == CFBooleanGetTypeID()) { on = CFBooleanGetValue((CFBooleanRef)enabled); }
        CFRelease(enabled);
    }
    if (!on) { return; }
    double ratio = 30.0, len = 64.0;
    CFPropertyListRef y = CFPreferencesCopyAppValue(CFSTR("GripY"), CFSTR("com.Aevon"));
    if (y != NULL) {
        if (CFGetTypeID(y) == CFNumberGetTypeID()) { CFNumberGetValue((CFNumberRef)y, kCFNumberDoubleType, &ratio); }
        CFRelease(y);
    }
    CFPropertyListRef l = CFPreferencesCopyAppValue(CFSTR("GripLen"), CFSTR("com.Aevon"));
    if (l != NULL) {
        if (CFGetTypeID(l) == CFNumberGetTypeID()) { CFNumberGetValue((CFNumberRef)l, kCFNumberDoubleType, &len); }
        CFRelease(l);
    }
    if (ratio < 10) { ratio = 10; }
    if (ratio > 90) { ratio = 90; }
    if (len < 36) { len = 36; }
    if (len > 120) { len = 120; }
    CGSize screen = gAevonRealScreen;
    if (screen.width < 100 || screen.height < 200) { return; }
    const double barWidth = 5.0, outsetX = 40.0, outsetY = 14.0;
    double cy = screen.height * (1.0 - ratio / 100.0);
    double hitW = barWidth + outsetX;
    double hitH = len + outsetY * 2.0;
    gAevonGripRect = CGRectMake(screen.width - hitW, cy - hitH / 2.0, hitW, hitH);
}

static BOOL AevonPointInGrip(CGPoint p) {
    AevonGripRefreshCache();
    return !CGRectIsEmpty(gAevonGripRect) && CGRectContainsPoint(gAevonGripRect, p);
}

/* V0.2.61（AevonGripSwallowV261）：这一拍能不能吞？
 * 两条硬闸，都是为了不在别人的 App 里误伤正常操作：
 *   1) 只在**App 占满整屏**时吞 —— 进浮窗后 App 的 window 高度就是画布 737，
 *      这时把手在屏幕右缘、跟 App 内容不在一个位置，吞了只会平白吃掉浮窗内的点击；
 *   2) 键盘在屏上时不吞（见 AevonKeyboardVisible 的注释：会压住键盘右列）。
 * 判据全部用真屏幕（被接管前的 -[UIScreen bounds] 原实现），不用被接管过的值。 */
/* V0.2.65（AevonEdgeShieldV265，用户 Aevon(38) #1 #2）：
 *   #1「每次在全屏 App 中触发圆盘，第一次都会触发应用内操作，后续不会」
 *   #2「在全屏 App 中操作悬浮窗时会触发全屏 App 的操作（例如双击悬浮窗）」
 *
 * 两件事同一个根：**backboardd 会把同一根手指同时投给 SpringBoard（我们的浮窗 /
 * 把手）和 App 进程**。前面几版靠「广播把手占用 → 把 App 所有窗口 userInteraction
 * 关掉」，依赖两件事：①通知必须在 UIKit 派发这一帧之前到达；②闸门
 * `AevonAppIsFloatHosted()` 必须已经是 NO。第②条正是「第一次失效」的元凶 ——
 * App 刚从浮窗转回全屏时，承载标记还在 0.30 秒去抖窗口里，闸门仍判「被承载」→
 * 整段跳过 → 第一下滑把手被 App 吃掉；等标记翻过来，后面的就都好了。
 *
 * 现在改成**纯几何、无闸门、无时序依赖**：SB 把主浮窗的屏幕矩形写进偏好
 * `AevonFloatFrame`（"x,y,w,h"），App 侧在 `-sendEvent:` 里判一次点：
 *   · 落在浮窗内 + 落在浮窗的**边条/底条/把手贴边带** → 吞（那是浮窗的手势区）；
 *   · 落在浮窗内的中间内容区 → 不吞（浮窗里的 App 要能点）；
 *   · 落在浮窗外 + 落在右缘把手带 → 吞（全屏 App 里滑把手，App 不许跟手）。
 * 判据只看坐标，第一次和第一百次完全一样。 */
static CGRect gAevonFloatFrameCache = {{0, 0}, {0, 0}};
static CFTimeInterval gAevonFloatFrameReadAt = 0;

/* V0.2.73（AevonRectNotifyV273，用户 Aevon(45) #4/#6）：notify state 矩形通道
 * —— 与 shim 内 AevonFloatRectRead 同款，App 侧不链 shim 所以内置。
 * 文件通道 /var/mobile/Library/Aevon/floatframe.txt 在 Filza/设置这类系统工具
 * 进程里验过能读，但 mqq 全篇 0 条边带日志 + 用户实测边带失效 = QQ 这类带
 * container 沙盒约束的 App 读不到该路径。notifyd 的 token state 全进程可达，
 * 无沙盒无路径依赖；范围校验（40~4000pt + NaN 拒收）当 magic，零矩形过不了。 */
static int AevonRectTokenNamed(NSString *name) {
    static NSDictionary<NSString *, NSNumber *> *tokens = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSNumber *> *m = [NSMutableDictionary dictionary];
        for (NSString *n in @[@"com.aevon.floatrect.a", @"com.aevon.floatrect.b"]) {
            int t = -1;
            notify_register_check(n, &t);
            m[n] = @(t);
        }
        tokens = [m copy];
    });
    return tokens[name].intValue;
}

static BOOL AevonRectNotifyRead(CGRect *outRect) {
    int ta = AevonRectTokenNamed(@"com.aevon.floatrect.a");
    int tb = AevonRectTokenNamed(@"com.aevon.floatrect.b");
    if (ta < 0 || tb < 0) { return NO; }
    uint64_t pa = 0, pb = 0;
    if (notify_get_state(ta, &pa) != NOTIFY_STATUS_OK) { return NO; }
    if (notify_get_state(tb, &pb) != NOTIFY_STATUS_OK) { return NO; }
    uint32_t raw[4] = {
        (uint32_t)(pa >> 32), (uint32_t)(pa & 0xFFFFFFFF),
        (uint32_t)(pb >> 32), (uint32_t)(pb & 0xFFFFFFFF)
    };
    float v[4];
    memcpy(v, raw, sizeof(v));
    for (int i = 0; i < 4; i++) {
        if (v[i] != v[i] || v[i] < -10.0f || v[i] > 4000.0f) { return NO; }  /* NaN/范围 */
    }
    if (v[2] < 40.0f || v[3] < 40.0f) { return NO; }
    if (outRect) { *outRect = CGRectMake(v[0], v[1], v[2], v[3]); }
    return YES;
}

__attribute__((used)) static const char AevonRectNotifyV273Marker[] = "AevonRectNotifyV273";

static CGRect AevonFloatFrameRect(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gAevonFloatFrameReadAt < 0.5 && gAevonFloatFrameReadAt > 0) {
        return gAevonFloatFrameCache;
    }
    gAevonFloatFrameReadAt = now;
    CGRect rect = CGRectZero;
    @try {
        /* V0.2.73（AevonRectNotifyV273）：**优先 notify 通道**。 */
        CGRect fromNotify = CGRectZero;
        if (AevonRectNotifyRead(&fromNotify)) {
            gAevonFloatFrameCache = fromNotify;
            return fromNotify;
        }
        /* V0.2.66（AevonFrameFileV266）：文件通道（系统工具类 App 仍走这里）。 */
        NSString *text = nil;
        NSString *filePath = @"/var/mobile/Library/Aevon/floatframe.txt";
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:filePath error:nil];
        if (attrs != nil) {
            text = [NSString stringWithContentsOfFile:filePath
                                             encoding:NSUTF8StringEncoding error:nil];
            text = [text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (text.length == 0) {
            CFPreferencesAppSynchronize(CFSTR("com.Aevon"));
            CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("AevonFloatFrame"), CFSTR("com.Aevon"));
            if (raw != NULL) {
                if (CFGetTypeID(raw) == CFStringGetTypeID()) {
                    text = [NSString stringWithString:(__bridge NSString *)raw];
                }
                CFRelease(raw);
            }
        }
        if (text.length > 0) {
            NSArray<NSString *> *parts = [text componentsSeparatedByString:@","];
            if (parts.count >= 4) {
                rect = CGRectMake(parts[0].doubleValue, parts[1].doubleValue,
                                  parts[2].doubleValue, parts[3].doubleValue);
            }
            if (rect.size.width < 40 || rect.size.height < 40) { rect = CGRectZero; }
        }
    } @catch (NSException *exception) {
        rect = CGRectZero;
    }
    gAevonFloatFrameCache = rect;
    return rect;
}

/* V0.2.65（AevonEdgeShieldV265）：这一点是不是落在浮窗「自己的手势区」——
 * 左/右 30pt 全高边条 + 底 44pt 全宽 + 顶 8pt。落在这里的触摸归浮窗（拖窗 / 双击关闭），
 * App 一根都不许接，否则用户双击浮窗关窗时全屏 App 也跟着收到双击。
 * V0.2.69（AevonFloatBandV269，用户 Aevon(41) #10「全屏 App 上叠浮窗：双击浮窗底边
 * 关窗、点边条拖动/吸附时依旧会触发 app 内操作」）：加**压边 10pt**（与 SB 侧
 * FloatGripOverlap 同口径）—— 边条触摸常落在浮窗矩形外沿 10pt 内（SB 侧手柄
 * 压边设计），原判据只在矩形内判 = 外沿那圈漏给 App。 */
__attribute__((used)) static const char AevonFloatBandV269Marker[] = "AevonFloatBandV269";

static BOOL AevonPointInFloatEdge(CGPoint p) {
    CGRect r = AevonFloatFrameRect();
    if (r.size.width < 40 || r.size.height < 40) { return NO; }
    if (!CGRectContainsPoint(r, p)) { return NO; }
    /* V0.2.72（AevonFloatBandWideV272，用户 Aevon(44) #1「依旧触发 App 内操作，
     * 可以适当加宽热区」）：手势带加宽 —— 30→44 / 底 44→64 / 顶 8→20。
     * Aevon(44) 19:46:08 实锤：落点 {286,710} 距底边 56pt，44pt 底带差 12pt 没进
     * =「点边条触发 App 内操作」。代价 = 边带更宽会多吞边上的 App 内触摸，
     * 用户已明确授权。 */
    CGFloat band = 44.0;
    CGFloat bottomBand = 64.0;
    return (p.x <= r.origin.x + band)
        || (p.x >= CGRectGetMaxX(r) - band)
        || (p.y <= r.origin.y + 20.0)
        || (p.y >= CGRectGetMaxY(r) - bottomBand);
}

/* V0.2.69（AevonFloatBandV269）：浮窗矩形外扩后再判一次手势带 ——
 * SB 侧手柄压边同口径，App 侧窄一圈就会把边条外沿的触摸漏给 App。
 * V0.2.72 外扩 10 → 22pt（AevonFloatBandWideV272）：矩形过期/口径差在
 * 12~22pt 级别时也能兜住。 */
static BOOL AevonPointInFloatEdgeInflated(CGPoint p) {
    CGRect r = CGRectInset(AevonFloatFrameRect(), -22.0, -22.0);
    if (r.size.width < 40 || r.size.height < 40) { return NO; }
    if (!CGRectContainsPoint(r, p)) { return NO; }
    CGFloat band = 44.0;
    CGFloat bottomBand = 64.0;
    return (p.x <= r.origin.x + band)
        || (p.x >= CGRectGetMaxX(r) - band)
        || (p.y <= r.origin.y + 20.0)
        || (p.y >= CGRectGetMaxY(r) - bottomBand);
}

/* V0.2.68（AevonCanvasBandV268，用户 Aevon(40) #5「全屏 App 上叠浮窗，双击浮窗底边
 * 关窗或点击吸附时依旧会触发全屏 App 的操作」）：
 * 0.2.67 的 `fullScreen` 闸门把**承载模式一刀切放行**了 —— Aevon(40) 16:02:37 与
 * 16:06:29（Sileo）两条「浮窗承载=是 …→ 吞=否」实锤：浮窗承载 App 时 App 窗口是
 * 画布尺寸（430x737），fullScreen=否，浮窗手势带的触摸整段放行 → 点浮窗边条 /
 * 双击底边关窗，浮窗里显示的那个 App 跟着动。0.2.66 的问题是「画布坐标比屏幕矩形」
 * 坐标系错配（误吞内容），0.2.67 修成全放行矫枉过正（该吞的不吞）。
 * 正解：承载模式下本窗口**就是**画布，SB 侧浮窗手势带（左/右 30pt、底 44pt、顶 8pt，
 * 屏幕 pt）按 canvasH / floatH **等比**映射到画布空间 —— 坐标系自洽，
 * 两个旧 bug（错配误吞 / 一刀切放行）一起根治。 */
static BOOL AevonPointInCanvasBand(UIWindow *win, CGPoint p) {
    CGRect fb = AevonFloatFrameRect();
    if (fb.size.width < 40 || fb.size.height < 40) { return NO; }
    CGSize cs = win.bounds.size;
    if (cs.height < 40 || cs.width < 40) { return NO; }
    CGFloat scale = cs.height / fb.size.height;
    CGFloat band = 30.0 * scale;
    CGFloat bottomBand = 44.0 * scale;
    CGFloat topBand = 8.0 * scale;
    return (p.x <= band)
        || (p.x >= cs.width - band)
        || (p.y <= topBand)
        || (p.y >= cs.height - bottomBand);
}

static BOOL AevonShouldConsiderSwallow(UITouch *touch, CGPoint p) {
    /* V0.2.63（AevonGripSwallowFixV263）：不再要求 `touch.window != nil`。
     * UIApplication 这一层 touch.window 恒为 nil（0.2.61 实测），但
     * `-locationInView:nil` 拿到的就是**屏幕坐标**，够判定了。
     *
     * V0.2.65（AevonEdgeShieldV265）：闸门从「本 App 被浮窗承载就整段不动」
     * 换成「看这一点在哪」—— 承载标记会抖、会延迟，坐标不会。 */
    CGSize real = AevonRealScreenSize();
    if (real.height < 200) { return NO; }
    if (AevonKeyboardVisible()) { return NO; }
    if (AevonFloatFrameRect().size.width > 40) {
        /* 浮窗内的触摸：手势区（边条/底条/顶条）吞，内容区不吞（浮窗里的 App 要能点）。 */
        if (CGRectContainsPoint(AevonFloatFrameRect(), p)) {
            return AevonPointInFloatEdge(p);
        }
    }
    return AevonPointInGrip(p);
}

/* V0.2.63：右缘落点诊断的限频时间戳（两个钩子共用） */
static CFTimeInterval gAevonGripMissLoggedAt;

static void AevonSendEventSwizzled(id self, SEL _cmd, UIEvent *event) {
    @try {
        NSSet *touches = [event allTouches];
        if (touches.count > 0) {
            if (gAevonSwallowedTouches == nil) { gAevonSwallowedTouches = [NSMutableSet set]; }
            BOOL anySwallowed = NO;
            BOOL allSwallowed = YES;
            NSMutableArray *finished = nil;
            for (UITouch *touch in touches) {
                NSValue *key = [NSValue valueWithPointer:(__bridge const void *)touch];
                if (touch.phase == UITouchPhaseBegan) {
                    /* V0.2.63：这一层 `touch.window` 恒为 nil，用 nil 视图取到的
                     * 就是屏幕坐标（也对得上把手命中区）。 */
                    CGPoint p = [touch locationInView:nil];
                    /* 诊断（限频 3s）：右缘 80pt 内的落点一律记一条 —— 万一还是没吞，
                     * 下一篇日志直接能看出是「点没到这一层」还是「坐标对不上」。 */
                    CGSize real = AevonRealScreenSize();
                    if (real.width > 100 && p.x >= real.width - 80.0) {
                        CFTimeInterval nowLog = CACurrentMediaTime();
                        if (nowLog - gAevonGripMissLoggedAt > 3.0) {
                            gAevonGripMissLoggedAt = nowLog;
                            AevonAppLog(@"[App侧] 右缘落点 %@（把手矩形 %@，真屏 %.0fx%.0f，"
                                        @"浮窗承载=%@，键盘=%@）→ 吞=%@"
                                        @"（AevonGripSwallowFixV263 AevonGripBusyV263）",
                                        NSStringFromCGPoint(p), NSStringFromCGRect(gAevonGripRect),
                                        real.width, real.height,
                                        AevonAppIsFloatHosted() ? @"是" : @"否",
                                        AevonKeyboardVisible() ? @"是" : @"否",
                                        AevonShouldConsiderSwallow(touch, p) ? @"是" : @"否");
                        }
                    }
                    /* V0.2.67（AevonSwallowOneV267，用户 Aevon(40) #8「0.2.66 有概率屏幕
                     * 点击失效」）：这一层**不再吞咽，只做诊断**。原因：UIApplication 层
                     * 拿不到 touch.window（恒 nil），locationInView:nil 在承载模式下返回
                     * 的是画布坐标（430x737 空间），而浮窗矩形/把手矩形都是 SB 屏幕坐标
                     * （430x932 空间）—— 两个坐标系差一个窗口原点+缩放，拿画布坐标比
                     * 屏幕矩形 = 误吞承载内容（Aevon(40) 14:51:00 的三连吞就是残留矩形
                     * 撞上这层无闸门的判定）。窗口层钩子有 win + fullScreen 闸门，
                     * 是唯一该吞的地方（V0.2.62 已定主通道）。 */
                    if (AevonShouldConsiderSwallow(touch, p)) {
                        CFTimeInterval nowLog2 = CACurrentMediaTime();
                        if (nowLog2 - gAevonGripMissLoggedAt > 3.0) {
                            gAevonGripMissLoggedAt = nowLog2;
                            AevonAppLog(@"[App侧] 命中吞咽判据（本层只记不吞，吞咽在窗口层）"
                                        @"%@（AevonSwallowOneV267）", NSStringFromCGPoint(p));
                        }
                    }
                }
                BOOL swallowed = [gAevonSwallowedTouches containsObject:key];
                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    if (swallowed) {
                        if (finished == nil) { finished = [NSMutableArray array]; }
                        [finished addObject:key];
                    }
                }
                if (swallowed) { anySwallowed = YES; } else { allSwallowed = NO; }
            }
            if (anySwallowed && allSwallowed) {
                for (NSValue *key in finished) { [gAevonSwallowedTouches removeObject:key]; }
                return;   /* 整条事件不投递：App 侧手势 / 视图永远看不到这一根手指 */
            }
            for (NSValue *key in finished) { [gAevonSwallowedTouches removeObject:key]; }
        }
    } @catch (NSException *exception) {
        AevonAppLog(@"[App侧] 把手吞咽判定异常：%@（不影响宿主）（AevonGripSwallowV261）",
                    exception.reason ?: @"未知");
    }
    ((void (*)(id, SEL, UIEvent *))gAevonSendEventOrig)(self, _cmd, event);
}

#pragma mark - V0.2.62：把手吞咽改在窗口层（AevonGripSwallowWinV262）

/*
 * 用户 Aevon(36) #7：「滑动把手时还是会触发 App 内的操作」。
 *
 * 0.2.61 把拦截放在 `-[UIApplication sendEvent:]`，但 Aevon(36) 整篇日志**一条
 * 「把手区落点」都没有**（只有 10 条「已接管」）—— 说明判定从来没通过。真凶是
 * `AevonShouldConsiderSwallow` 里第一行 `UIWindow *w = touch.window; if (w == nil)
 * return NO;`：在 UIApplication 这一层，UIKit **还没把 touch 关联到窗口**
 * （window 是在 `-[UIWindow sendEvent:]` 里才确定的），所以 touch.window 恒为 nil
 * → 判定恒失败 → 一根都没吞。
 *
 * 修法：改挂 `-[UIWindow sendEvent:]`。这一层 self 就是窗口，坐标用
 * `[touch locationInView:self]`（全屏窗口下与屏幕坐标一致），窗口尺寸也能直接查。
 * UIApplication 那一层保留（有些 App 会自己分发），两层都在时以窗口层为准（幂等）。
 */
__attribute__((used)) static const char AevonGripSwallowWinV262Marker[] = "AevonGripSwallowWinV262";

#pragma mark - V0.2.71：圆盘在屏 → App 进程整根吞（AevonRingSwallow2V271）

/*
 * 用户 Aevon(43) #3：「划出圆盘后再在圆盘上滑动，全屏 app 页面也跟着上下/左右滑」。
 *
 * 圆盘是 SB 侧窗口，命中归圆盘；但 backboardd 会把同一批触摸**双投**进前景 App
 * 进程 —— 圆盘动、App 也动。修法：SpringBoard 早就把「圆盘展开」写在共享内存
 * 状态位（com.aevon.guardzone bit39，AevonNotifyRingBitV34，零时序依赖），
 * 这里恢复 App 侧读取器：位=1 时本进程的 sendEvent 把事件整根吞掉。
 * App 侧 dylib 不链 AevonAssertionShim.m，这里内置同一套位格式（低 32 位 =
 * 设置时刻 CLOCK_MONOTONIC 秒，30 秒新鲜度防 SB 崩溃后位没清把 App 吞哑）。
 */
__attribute__((used)) static const char AevonRingSwallow2V271Marker[] = "AevonRingSwallow2V271";

static int gAevonRingZoneToken = -1;

static int AevonRingActiveNow(void) {
    if (gAevonRingZoneToken < 0) {
        notify_register_check("com.aevon.guardzone", &gAevonRingZoneToken);
        if (gAevonRingZoneToken < 0) { return 0; }
    }
    uint64_t pack = 0;
    if (notify_get_state(gAevonRingZoneToken, &pack) != NOTIFY_STATUS_OK) { return 0; }
    if (((pack >> 40) & 0xFF) != 0x34) { return 0; }
    if (!(pack & (1ULL << 39))) { return 0; }
    uint32_t setAt = (uint32_t)(pack & 0xFFFFFFFFULL);
    uint32_t now = (uint32_t)(clock_gettime_nsec_np(CLOCK_MONOTONIC) / NSEC_PER_SEC);
    if (setAt != 0 && now - setAt > 30) { return 0; }
    return 1;
}

static IMP gAevonWinSendEventOrig;

static void AevonWindowSendEventSwizzled(id self, SEL _cmd, UIEvent *event) {
    @try {
        /* V0.2.71（AevonRingSwallow2V271）：圆盘在屏 → 本进程整根不投递。
         * 已登记的吞咽钥匙在抬手时顺手清掉（防集合滞留）。 */
        if (AevonRingActiveNow()) {
            NSSet *ringTouches = [event allTouches];
            for (UITouch *t in ringTouches) {
                if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) {
                    [gAevonSwallowedTouches removeObject:
                        [NSValue valueWithPointer:(__bridge const void *)t]];
                }
            }
            return;
        }
        UIWindow *win = (UIWindow *)self;
        NSSet *touches = [event allTouches];
        if (touches.count > 0) {
            /* 命中区缓存在第一次触摸时可能还没算过 —— 这里先刷一次再说（每 2 秒最多
             * 读一次偏好，代价可忽略），否则「刚开 App 的第一下滑把手」永远不吞。 */
            AevonGripRefreshCache();
            if (gAevonSwallowedTouches == nil) { gAevonSwallowedTouches = [NSMutableSet set]; }
            BOOL anySwallowed = NO;
            BOOL allSwallowed = YES;
            NSMutableArray *finished = nil;
            for (UITouch *touch in touches) {
                NSValue *key = [NSValue valueWithPointer:(__bridge const void *)touch];
                if (touch.phase == UITouchPhaseBegan) {
                    CGPoint p = [touch locationInView:win];
                    AevonGripRefreshCache();
                    BOOL inRect = !CGRectIsEmpty(gAevonGripRect) && CGRectContainsPoint(gAevonGripRect, p);
                    CGSize real = AevonRealScreenSize();
                    BOOL fullScreen = win.bounds.size.height >= real.height - 60.0;
                    /* V0.2.67（AevonShieldFSV267，用户 Aevon(40) #8）：浮窗手势区吞噬
                     * 必须**只在 App 占满整屏时生效**。本 App 被浮窗承载时，窗口坐标是
                     * 画布空间（430x737），而浮窗矩形是 SB 侧屏幕坐标（430x932）——
                     * 两个坐标系相差一个窗口原点 + 缩放，拿画布坐标去比屏幕矩形，
                     * 既会误吞承载内容（右缘 30pt 带整条失效），也拦不住真正的窗边手势
                     * （窗边手势由 SB 侧浮窗自己处理，App 侧根本不用管）。
                     * V0.2.68（AevonCanvasBandV268，用户 Aevon(40) #5）：承载模式
                     * **不再一刀切放行** —— 那等于把「点浮窗边条带动浮窗里的 App」
                     * 合法化。承载模式下改按**画布自身边缘带**判定（坐标系自洽）。 */
                    if (fullScreen && (AevonPointInFloatEdge(p)
                                       || AevonPointInFloatEdgeInflated(p))) {
                        [gAevonSwallowedTouches addObject:key];
                        AevonAppLog(@"[App侧] 浮窗手势区落点 %@（浮窗矩形 %@）→ 整根丢弃（窗边归浮窗，"
                                    @"App 内的双击/滑动不许被带着走）（AevonEdgeShieldV265 "
                                    @"AevonFloatBandV269）",
                                    NSStringFromCGPoint(p),
                                    NSStringFromCGRect(AevonFloatFrameRect()));
                    } else if (!fullScreen && !AevonKeyboardVisible()
                               && AevonPointInCanvasBand(win, p)) {
                        [gAevonSwallowedTouches addObject:key];
                        AevonAppLog(@"[App侧] 画布边缘带落点 %@ → 整根丢弃（承载模式：浮窗"
                                    @"边条/底边归浮窗手势，浮窗里的 App 不许跟手）"
                                    @"（AevonCanvasBandV268）", NSStringFromCGPoint(p));
                    } else if (inRect && fullScreen && !AevonKeyboardVisible()) {
                        [gAevonSwallowedTouches addObject:key];
                        AevonAppLog(@"[App侧] 把手区落点 %@ → 整根触摸丢弃（窗口层，"
                                    @"不再带着 App 内滑动）（AevonGripSwallowV261 "
                                    @"AevonGripSwallowWinV262）", NSStringFromCGPoint(p));
                    } else if (fullScreen && !AevonKeyboardVisible()) {
                        /* V0.2.69（AevonFloatBandV269）：全屏 + 有浮窗矩形时的漏判诊断
                         * —— #10 复发时这条直接给出「落点 vs 矩形」的差值，
                         * 不用再猜是矩形过期还是带宽不够。排在把手分支之后只诊断不吞。
                         * V0.2.73（AevonFloatBandV273）：诊断口径与吞判定**完全同款**
                         *（矩形外扩 22pt，Aevon(45) 是 10pt 旧口径——22pt 与 10pt 之间
                         * 的落点判否吞不掉也不打日志 = 诊断盲区）；限频 5s → 2s。 */
                        CGRect r = AevonFloatFrameRect();
                        CGRect inflated = CGRectInset(r, -22.0, -22.0);
                        if (r.size.width > 40 && CGRectContainsPoint(inflated, p)) {
                            CFTimeInterval nowB = CACurrentMediaTime();
                            if (nowB - gAevonGripMissLoggedAt > 2.0) {
                                gAevonGripMissLoggedAt = nowB;
                                AevonAppLog(@"[App侧] 浮窗外沿落点 %@ 未吞（矩形 %@，压边判否，"
                                            @"疑矩形过期/带宽不够）（AevonFloatBandV269）",
                                            NSStringFromCGPoint(p), NSStringFromCGRect(r));
                            }
                        }
                    } else if (inRect) {
                        /* 中了矩形却没吞：留一条可诊断的证（5 秒限频），
                         * 下次出问题不用再靠猜（浮窗内 / 键盘在屏 / 窗口不是全屏）。 */
                        CFTimeInterval now = CACurrentMediaTime();
                        if (now - gAevonGripMissLoggedAt > 5.0) {
                            gAevonGripMissLoggedAt = now;
                            AevonAppLog(@"[App侧] 把手区命中但按纪律不吞：窗口高 %.0f（真屏 %.0f，"
                                        @"全屏=%@）键盘在屏=%@（AevonGripSwallowWinV262）",
                                        win.bounds.size.height, real.height,
                                        fullScreen ? @"是" : @"否",
                                        AevonKeyboardVisible() ? @"是" : @"否");
                        }
                    }
                }
                BOOL swallowed = [gAevonSwallowedTouches containsObject:key];
                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    if (swallowed) {
                        if (finished == nil) { finished = [NSMutableArray array]; }
                        [finished addObject:key];
                    }
                }
                if (swallowed) { anySwallowed = YES; } else { allSwallowed = NO; }
            }
            if (anySwallowed && allSwallowed) {
                for (NSValue *key in finished) { [gAevonSwallowedTouches removeObject:key]; }
                return;
            }
            for (NSValue *key in finished) { [gAevonSwallowedTouches removeObject:key]; }
        }
    } @catch (NSException *exception) {
        AevonAppLog(@"[App侧] 窗口层吞咽异常：%@（不影响宿主）（AevonGripSwallowWinV262）",
                    exception.reason ?: @"未知");
    }
    if (gAevonWinSendEventOrig != NULL) {
        ((void (*)(id, SEL, UIEvent *))gAevonWinSendEventOrig)(self, _cmd, event);
    }
}

static void AevonGripSwallowInstall(void) {
    @try {
        /* V0.2.62：窗口层是主通道（UIApplication 那一层拿不到 touch.window）。 */
        if (gAevonWinSendEventOrig == NULL) {
            Method wm = class_getInstanceMethod([UIWindow class], @selector(sendEvent:));
            if (wm != NULL) {
                const char *wtypes = method_getTypeEncoding(wm);
                if (wtypes != NULL && wtypes[0] == 'v' && strstr(wtypes, "@0:8@") != NULL) {
                    gAevonWinSendEventOrig = method_getImplementation(wm);
                    method_setImplementation(wm, (IMP)AevonWindowSendEventSwizzled);
                    AevonAppLog(@"[App侧] 已接管 -[UIWindow sendEvent:]：把手命中区内的触摸整根丢弃"
                                @"（主通道，窗口层拿得到 touch.window）"
                                @"（AevonGripSwallowV261 AevonGripSwallowWinV262）");
                } else {
                    AevonAppLog(@"[App侧] UIWindow sendEvent: 编码异常（%s），窗口层不装"
                                @"（AevonGripSwallowWinV262）", wtypes ?: "nil");
                }
            }
        }
        if (gAevonSendEventOrig != NULL) { return; }
        Method m = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
        if (m == NULL) {
            AevonAppLog(@"[App侧] 没有 -[UIApplication sendEvent:]，把手吞咽不装（AevonGripSwallowV261）");
            return;
        }
        const char *types = method_getTypeEncoding(m);
        /* 0.2.52 的纪律：hook 前必须自检类型编码，形状不符一律不装（fail-closed）。
         * -[UIApplication sendEvent:] 必须是「返回 void、self + _cmd + 一个对象参数」：
         * 判据 = 首字母 v 且含 "@0:8@"（对象实参段）。 */
        if (types == NULL || types[0] != 'v' || strstr(types, "@0:8@") == NULL) {
            AevonAppLog(@"[App侧] sendEvent: 类型编码异常（%s），把手吞咽不装（AevonGripSwallowV261）",
                        types ?: "nil");
            return;
        }
        gAevonSendEventOrig = method_getImplementation(m);
        method_setImplementation(m, (IMP)AevonSendEventSwizzled);
        AevonAppLog(@"[App侧] 已接管 -[UIApplication sendEvent:]：把手命中区（右缘竖条 + 内 40pt /"
                    @"上下各 14pt）内的触摸整根丢弃，全屏 App 里滑把手不再带动 App 内滑动"
                    @"（AevonGripSwallowV261）");
    } @catch (NSException *exception) {
        AevonAppLog(@"[App侧] 把手吞咽安装失败：%@（AevonGripSwallowV261）",
                    exception.reason ?: @"未知");
    }
}

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
                    /* V0.2.49（AevonAppScreenFitV249）：先接管屏幕尺寸，再挂识别器 ——
                     * 顺序反了会让第一遍布局用整屏尺寸（真重排要等下一次布局）。 */
                    AevonScreenFitInstall();
                    /* V0.2.61（AevonGripSwallowV261）：把手命中区的触摸在 App 进程内整根丢掉。 */
                    AevonGripSwallowInstall();
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