#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
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
 * 落地：本进程算完合并写 /var/mobile/aevon_caps.txt（`bundleID=1/0` 逐行），
 * SB 侧开窗前读（AevonSelfSceneAppCapVerdict）；读不到 = 未知 → 维持自建（旧行为）。
 * delegate 未就绪（nil）不写，绝不把「判断不了」记成 0。 */
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
        NSString *path = @"/var/mobile/aevon_caps.txt";
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (old.length > 0) {
            for (NSString *line in [old componentsSeparatedByString:@"\n"]) {
                NSRange eq = [line rangeOfString:@"="];
                if (eq.location == NSNotFound) { continue; }
                NSString *k = [line substringToIndex:eq.location];
                NSString *v = [line substringFromIndex:eq.location + 1];
                if (k.length > 0) { dict[k] = v; }
            }
        }
        dict[bid] = cap ? @"1" : @"0";
        NSMutableString *merged = [NSMutableString string];
        for (NSString *k in dict.allKeys) {
            [merged appendFormat:@"%@=%@\n", k, dict[k]];
        }
        BOOL ok = [merged writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        AevonAppLog(@"场景能力登记：cap=%d（delegate=%@，写入=%d）（AevonAppSceneCapV241）",
                    cap ? 1 : 0, NSStringFromClass([delegate class]), ok ? 1 : 0);
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

static void AevonScreenFitNudgeLayout(BOOL nowOn) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { return; }
        NSInteger touched = 0;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
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
        AevonAppLog(@"屏幕贴合：状态翻转 → %@，已让 %ld 个窗口立即重排（防止「按画布排版、"
                    @"占整屏窗口」的残留黑屏）（AevonAppFitRelayoutV250）",
                    nowOn ? @"开（改报画布尺寸）" : @"关（回到真实屏幕尺寸）",
                    (long)touched);
    } @catch (NSException *exception) {
        /* 敲布局失败不影响宿主：下一次系统 resize 仍会自愈 */
    }
}

static void AevonScreenFitRefresh(void) {
    if (gAevonScreenFitRefreshing) { return; }
    gAevonScreenFitRefreshing = YES;
    BOOL flipped = NO;
    BOOL nowOn = NO;
    @try {
        BOOL on = AevonAppIsFloatHosted();
        nowOn = on;
        if (on != gAevonScreenFitOn || !gAevonScreenFitLogged) {
            flipped = (on != gAevonScreenFitOn);
            gAevonScreenFitOn = on;
            gAevonScreenFitLogged = YES;
            AevonAppLog(@"屏幕贴合：%@（AevonAppScreenFitV249）",
                        on ? @"开 —— 本 App 正被浮窗承载，UIScreen 改报画布尺寸"
                           : @"关 —— 按真实屏幕报告");
        }
        gAevonScreenFitCheckedAt = CACurrentMediaTime();
    } @catch (NSException *exception) {
        gAevonScreenFitOn = NO;
    }
    gAevonScreenFitRefreshing = NO;
    if (flipped) { AevonScreenFitNudgeLayout(nowOn); }
    /* V0.2.59（AevonDockStageV259）：0.5s 轮询兜底刷新停靠交互（事件驱动为主）。 */
    AevonDockInteractionRefresh();
}

static CGRect AevonScreenBoundsFit(id self_, SEL _cmd) {
    if (gAevonScreenBoundsOrigIMP == NULL) { return CGRectZero; }
    CGRect real = ((CGRect (*)(id, SEL))gAevonScreenBoundsOrigIMP)(self_, _cmd);
    @try {
        CFTimeInterval now = CACurrentMediaTime();
        if (now - gAevonScreenFitCheckedAt >= 0.5) { AevonScreenFitRefresh(); }
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
static BOOL gAevonDockStageOnce = NO;
static BOOL gAevonDockActive = NO;

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
        if (docked == gAevonDockActive) { return; }
        gAevonDockActive = docked;
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { return; }
        NSInteger touched = 0;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                BOOL want = !docked;
                if (window.isUserInteractionEnabled != want) {
                    window.isUserInteractionEnabled = want;
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

static void AevonDockInteractionInstall(void) {
    @try {
        if ([gAevonAppBundleID isEqualToString:@"com.apple.springboard"]) { return; }
        if (gAevonDockStageNotifyToken < 0) {
            notify_register_dispatch("com.aevon.dockstage", &gAevonDockStageNotifyToken,
                                     dispatch_get_main_queue(), ^(int token) {
                AevonDockInteractionRefresh();
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
    } @catch (NSException *exception) {
        AevonAppLog(@"屏幕贴合：接管失败 %@（不影响宿主，按真实屏幕走）（AevonAppScreenFitFailV249）",
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