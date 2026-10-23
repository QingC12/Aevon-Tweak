/*
 * AevonGuard —— App 进程侧的「圆盘热区触摸拦截」。
 *
 * 为什么必须有它（V0.0.27 的核心修复）
 * =====================================================================
 * Aevon.dylib 只注入 SpringBoard。实测（Aevon(20) 日志）在 SpringBoard 的
 * `UIApplication -sendEvent:` 里丢弃触摸，能挡住 App 的滚动，但挡不住
 * **App 自己的横向手势**：QQ 的左滑删除会话、抖音的左滑进作者主页照样触发。
 *
 * 原因：前台 App 的触摸事件是 backboardd 直接投递给 **App 进程**的，
 * SpringBoard 只是同时收到一份。在 SpringBoard 里吞事件，App 进程那一份照样存在。
 *
 * 所以这里再放一个「极小的纯 ObjC dylib」，注入到 GUI App 进程，只做一件事：
 * 热区内按下的那根手指，从 began 到 ended 的**整条事件都不投递给 App**。
 * App 连 began 都收不到 → 任何 App 内手势（左滑删除、左滑进主页、滚动、长按）
 * 都不可能被触发。
 *
 * 安全设计（绝不能影响没启用插件的机器）：
 *   · 不是 GUI 进程（没有 UIApplication / 是 SpringBoard）→ 构造函数直接 return；
 *   · `Enabled` 默认 false → 未启用时 hook 里第一行就原样转发，零行为变化；
 *   · hook 里任何异常都不抛给 App：只用 CFPreferences / UIKit 公开 API；
 *   · 只拦「热区内按下」的那一根手指，其它手指照常给 App。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>
#import <notify.h>

/// CI 标记：构建后校验这段逻辑确实编进了 __cstring
__attribute__((used)) static const char AevonAppGuardMarker[] = "AevonAppGuardV27";

/// CI 标记（V0.0.29）：圆盘展开期「下半屏整块吞掉」
__attribute__((used)) static const char AevonGuardRingZoneMarker[] = "AevonGuardRingZoneV29";

/// CI 标记（V0.0.31）：guard.conf 文件通道配置（沙盒 App 读不到偏好域的根治）
__attribute__((used)) static const char AevonGuardFileConfMarker[] = "AevonGuardFileConfV31";

/// CI 标记（V0.0.32）：notify(3) 主配置通道 + 圆盘展开期无条件吞下半屏
__attribute__((used)) static const char AevonGuardNotifyMarker[] = "AevonGuardNotifyV32";
__attribute__((used)) static const char AevonGuardRingForceMarker[] = "AevonGuardRingForceV32";
/// CI 标记（V0.0.33）：圆盘期吞区加宽到上 18% 以外整屏 + 60s 超时
__attribute__((used)) static const char AevonGuardRingWideMarker[] = "AevonGuardRingWideV33";
/// CI 标记（V0.0.34）：圆盘状态读 notify(3) 共享内存位（Darwin 广播不可靠的根治）
__attribute__((used)) static const char AevonGuardStateRingMarker[] = "AevonGuardStateRingV34";
/// CI 标记（V0.0.34）：Guard 自身写 Aevon.log（验证注入 / 吞摸计数，可诊断）
__attribute__((used)) static const char AevonGuardLogMarker[] = "AevonGuardLogV34";
/// CI 标记（V0.0.35）：ack 回执（Guard 读到圆盘状态 → post com.aevon.guardack，SB 写日志确证注入）
__attribute__((used)) static const char AevonGuardAckMarker[] = "AevonGuardAckV35";
/// CI 标记（V0.0.37）：圆盘状态判定修精确 —— notify 状态有效时 bit39 唯一裁决，
/// 60s 时间窗兜底只在状态通道不可用时启用（Aevon(30)：圆盘收起后 60 秒内整屏被吞，
/// QQ 分享到 Sileo 点不动的根因就是兜底时间窗在 bit39=0 时仍然为真）
__attribute__((used)) static const char AevonGuardRingExactV37Marker[] = "AevonGuardRingExactV37";
/// CI 标记（V0.0.49）：浮窗手势期 App 侧拦截 —— backboardd 双投递漏洞的最后一块补丁
__attribute__((used)) static const char AevonGuardFloatTouchV49Marker[] = "AevonGuardFloatTouchV49";
/// CI 标记（V0.0.54）：按停靠列**固定几何**吞摸 —— 与触摸时序无关，快速连点也不会漏
__attribute__((used)) static const char AevonGuardDockZoneV54Marker[] = "AevonGuardDockZoneV54";
/// CI 标记（V0.0.56）：触摸接管标记改 associated object —— 修「屏幕部分位置无法点击」
__attribute__((used)) static const char AevonGuardTouchMarkV56Marker[] = "AevonGuardTouchMarkV56";
/// CI 标记（V0.0.56）：主悬浮窗矩形通道（双击底边 / 快速连点仍点到 App 的根治）
__attribute__((used)) static const char AevonGuardFloatRectV56Marker[] = "AevonGuardFloatRectV56";
/// CI 标记（V0.0.57）：停用 App 窗口改写 —— 只保留「还原整屏」的单向兜底
__attribute__((used)) static const char AevonNoWinResizeV57Marker[] = "AevonNoWinResizeV57";
/// CI 标记（V0.0.59）：浮窗手势期状态位白名单补 0x36 —— V56 重构时漏了新版本号，
/// bit48 自 V54 起整条失效（SB 写 0x36，Guard 只认 0x34/0x35）
__attribute__((used)) static const char AevonGuardFloatBit36V59Marker[] = "AevonGuardFloatBit36V59";
/// CI 标记（V0.0.61）：扩展进程（.appex）绝不装 Guard —— 修「桌面部分小组件空白」
__attribute__((used)) static const char AevonGuardNoExtV61Marker[] = "AevonGuardNoExtV61";
__attribute__((used)) static const char AevonGuardGhostRecordV67Marker[] = "AevonGuardGhostRecordV67";

static CFStringRef const AevonGuardDomain = CFSTR("com.Aevon");
static IMP AevonGuardOrigSendEvent = NULL;
static BOOL AevonGuardEnabled = NO;
static CGRect AevonGuardZone = {{0, 0}, {0, 0}};
static CFTimeInterval AevonGuardConfigAt = 0;
/// 配置最长缓存时间（秒）。设置里改完会发 Darwin 通知立即失效，这里只是兜底。
static CFTimeInterval const AevonGuardConfigTTL = 2.0;

/* V0.0.29：圆盘展开状态。
 * V0.0.34（AevonGuardStateRingV34）：主判定改为 **notify(3) 共享内存位**（bit39）。
 * 旧的 Darwin 广播（com.aevon.ringopen / ringclose）是 fire-and-forget，沙盒 App
 * （抖音 / QQ）里可能收不到或收得晚 —— Aevon(27) 连续 3 版「圆盘滑动带动全屏 App」
 * 的共同根因。现在 SpringBoard 在圆盘开 / 关时写共享内存状态位（AevonNotifySetRing），
 * 这里每条 sendEvent 直接读，零时序依赖；Darwin 通知时间窗只做兜底。 */
static CFTimeInterval AevonGuardRingOpenAt = 0;
/* V0.0.33（AevonGuardRingWideV33）：10s → 60s（仅兜底通道使用） */
static CFTimeInterval const AevonGuardRingOpenMaxAge = 60.0;
/// V0.0.32：只要收到过 ringopen，就证明插件在 SpringBoard 侧是启用的。
/// 之后即使配置三路（notify / 文件 / 偏好）全失败，也用默认几何兜底拦截，
/// 不再整条 Guard 失效（Aevon(25)：guard.conf 写不进 → 抖音被暂停/误触）。
static BOOL AevonGuardPluginAlive = NO;

/* 前向声明（定义在下方 notify 通道区） */
static int AevonGuardNotifyToken(void);
/* 日志函数定义在下方，这里前置声明（原型与下面的定义完全一致） */
static void AevonGuardWriteLog(BOOL force, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);

static BOOL AevonGuardRingOpen(void) {
    /* 主判定：notify(3) 共享内存 bit39（每条事件实时读，微秒级开销）
     * V0.0.37（AevonGuardRingExactV37）：状态通道有效（版本字节 = 0x34）时，
     * bit39 是**唯一**裁决 —— bit=0 就立刻返回 NO 并清掉兜底时间窗。
     * 旧版的 bug：bit=0 时函数继续走时间窗兜底，而 RingOpenAt 停留在圆盘收起前
     * 最后一次刷新，于是收起后 60 秒内兜底恒真 → Guard 继续整屏吞触摸
     * （Aevon(30) 日志 18:28:50 收起 → 18:28:59 还在吞 41 条，QQ 分享 Sileo 点不动）。 */
    int token = AevonGuardNotifyToken();
    if (token >= 0) {
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        /* V0.0.56（AevonGuardRingExactV37 修正）：白名单补 0x36。
         *
         * V0.0.54 起 SpringBoard 写的版本号已经升到 0x36（多停靠列状态位），
         * 这里却仍只认 0x34 / 0x35 —— 于是共享内存状态位**整条被跳过**，
         * 掉进下面那条 60 秒时间窗兜底。结果就是圆盘收起之后最长 60 秒内
         * Guard 仍然整屏吞触摸：用户 Aevon(50) 第 3 条说的
         * 「插件会导致屏幕部分位置无法点击、全屏幕操作失效」正是它。
         * 版本号只有一处来源，这里必须跟着升。 */
        uint64_t ver = (pack >> 40) & 0xFFULL;
        if (ver == 0x34ULL || ver == 0x35ULL || ver == 0x36ULL) {
            if ((pack >> 39) & 1ULL) {
                AevonGuardRingOpenAt = CACurrentMediaTime();  /* 诊断用，不再参与判定 */
                return YES;
            }
            AevonGuardRingOpenAt = 0;
            return NO;
        }
    }
    /* 兜底：只在状态通道不可用（旧版 SB / token 注册失败）时才用 Darwin 时间窗 */
    if (AevonGuardRingOpenAt <= 0) { return NO; }
    return (CACurrentMediaTime() - AevonGuardRingOpenAt) < AevonGuardRingOpenMaxAge;
}

/* V0.0.49（AevonGuardFloatTouchV49）：浮窗手势期状态。
 *
 * Aevon(42) 第 1 条的根因写在本文件开头：前台 App 的触摸由 backboardd **直投 App 进程**，
 * SpringBoard 只是同时收到一份。我们在 SpringBoard 里吞掉自己那份之后，
 * 拖动看不出问题（App 只收到 moved、没有 began，UIKit 会丢弃无主移动），
 * 但一次**轻点**是 began + ended 完整的一对 —— App 那边照样合成一次点击，
 * 于是抖音「点小窗还原主窗」时视频被点停。
 *
 * 修法：SpringBoard 在浮窗手势按下时把 notify state bit48 置 1、抬手清 0；
 * 这里每条 sendEvent 直接读，置位期间把 App 进程收到的触摸整屏吞掉
 * （手指正压在浮窗上，App 本就不该收到任何输入）。
 *
 * 防呆：bit48 连续置位超过 8 秒就当成 SB 侧没清干净的残留（崩溃 / 强杀），
 * 立刻放行 —— 宁可少吞，也绝不能让 App 永久点不动。
 * 取 8 秒而不是 3 秒：真实拖动可能持续几秒，而轻点触发 App 内点击只发生在
 * 按下后的 0.5 秒内，8 秒窗足够覆盖，同时仍留了一条硬边界。 */
static BOOL AevonGuardFloatTouch(void) {
    static CFTimeInterval onSince = 0;
    static CFTimeInterval lastLoggedAt = 0;
    int token = AevonGuardNotifyToken();
    if (token < 0) { onSince = 0; return NO; }
    uint64_t pack = 0;
    notify_get_state(token, &pack);
    /* V0.0.59（AevonGuardFloatBit36V59）：白名单补 0x36。
     * V0.0.54 起 SB 写的版本号是 0x36，这里却只认 0x34/0x35 —— 于是浮窗手势期
     * （bit48）整条失效，Guard 只能靠浮窗矩形 / 停靠格两条几何判据兜底。
     * 补上后恢复「手指压在浮窗上 → App 进程整屏吞」的 V49 语义（8 秒防呆保留）。 */
    uint64_t ver = (pack >> 40) & 0xFFULL;
    if ((ver != 0x34ULL && ver != 0x35ULL && ver != 0x36ULL) || ((pack >> 48) & 1ULL) == 0) {
        onSince = 0;
        return NO;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (onSince <= 0) {
        onSince = now;
        /* 首次进入浮窗触摸期的日志（限频 1s）：下一版日志能确证 Guard 读到了这一位 */
        if (now - lastLoggedAt > 1.0) {
            lastLoggedAt = now;
            AevonGuardWriteLog(NO, @"浮窗触摸期 → Guard 在 App 进程内接管输入（AevonGuardFloatTouchV49）");
        }
    }
    if (now - onSince > 8.0) { return NO; }
    return YES;
}

/* V0.0.54（AevonGuardDockZoneV54）：停靠小窗区域的**几何**吞摸。
 *
 * Aevon(47) 第 5 条：「快速点击停靠的小窗轮换时，依旧会触发应用内的点击操作」。
 *
 * bit48（AevonGuardFloatTouch）是「SB 按下时写、抬手时清」的实时位 ——
 * 但前台 App 的触摸由 backboardd **同时**投递给 SB 与 App 两个进程，谁先到不确定。
 * 快速连点时抬手刚把 bit48 清掉、下一指的 began 已经在 App 进程里了，Guard 读到 0 就放行，
 * App 于是合成一次真实点击。这条竞态无法靠调时序消除。
 *
 * 但停靠列几何是**完全确定的**：顶部 10% 起步、每格 dockH+8、左右贴边、
 * 尺寸由屏宽反算成「5 格排得下」。所以 SB 只需要把「每侧几个停靠小窗」提前写进共享内存，
 * Guard 自己算出每个槽位矩形 —— 手指一落下就知道该不该吞，与触摸时序零关系。
 *
 * 抖音的右侧工具栏（x≈390~420）在停靠列之外，所以这里必须逐格精确判定，
 * 绝不能糊成「右侧一条全吞」，否则工具栏就点不动了。 */
static CGFloat gAevonDockW = 0;
static CGFloat gAevonDockH = 0;
static CGFloat gAevonDockTop = 0;
static CGFloat gAevonDockStep = 0;

/// 与 Swift 侧 `AevonSnap.dockSize` / `dockColumnYs` 完全一致的一套常量。
static void AevonGuardDockMetrics(void) {
    @try {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat sw = screen.size.width;
        CGFloat sh = screen.size.height;
        if (sw < 1 || sh < 200) { return; }
        CGFloat maxWidth = MAX(118.0, sw);                 // minContentWidth
        CGFloat dockFullW = MAX(96.0, MIN(sw * 0.28, maxWidth));   // dockMinWidth / dockWidthRatio
        CGFloat top = sh * 0.10;                           // dockTopRatio
        CGFloat avail = MAX(160.0, sh - top - 16.0);       // dockBottomMargin
        CGFloat slotGap = 8.0 * 4.0;                       // obstacleGap × (dockMaxCount − 1)
        CGFloat maxH = (avail - slotGap) / 5.0;            // dockMaxCount
        CGFloat h = MIN(dockFullW / 0.60, maxH);           // fatAspect
        CGFloat w = h * 0.60;
        if (w < 48.0) { w = 48.0; h = w / 0.60; }          // dockSlotMinWidth
        gAevonDockW = w;
        gAevonDockH = h;
        gAevonDockTop = top;
        gAevonDockStep = h + 8.0;
    } @catch (NSException *exception) {
    }
}

/// 读「左右各有几个停靠小窗」（bit50~52 / bit53~55）。返回总数（0 = 没有停靠列）。
static NSUInteger AevonGuardDockCounts(NSUInteger *outRight, NSUInteger *outLeft) {
    if (outRight) { *outRight = 0; }
    if (outLeft) { *outLeft = 0; }
    int token = AevonGuardNotifyToken();
    if (token < 0) { return 0; }
    uint64_t pack = 0;
    notify_get_state(token, &pack);
    uint64_t ver = (pack >> 40) & 0xFFULL;
    if (ver != 0x36ULL) { return 0; }   // 0x34/0x35 的 SB 没写这两位 → 走 bit48 老通道
    NSUInteger r = (NSUInteger)((pack >> 50) & 0x7ULL);
    NSUInteger l = (NSUInteger)((pack >> 53) & 0x7ULL);
    if (r > 5) { r = 5; }
    if (l > 5) { l = 5; }
    if (outRight) { *outRight = r; }
    if (outLeft) { *outLeft = l; }
    return r + l;
}

/// 停靠小窗「刚被点走」留下的幽灵格（V0.0.56）。
///
/// 轻点还原后小窗立刻离开该槽位、下方整列上移补位，而用户第二根手指往往
/// 几十毫秒后就落回**原槽位**——那里已经是 App 画面了。所以命中过的那一格
/// 在 1 秒内继续吞摸（同一只手连点 5 个也不会漏）。
static CGRect gAevonDockGhost = {{0, 0}, {0, 0}};
static CFTimeInterval gAevonDockGhostUntil = 0;

/// 点是否落在某一格停靠小窗上（外扩 3pt 容错，卡片的描边也能算进去）。
///
/// V0.0.56：命中后把那一格记成「幽灵格」保留 1 秒 —— 轻点还原后小窗立刻离开槽位、
/// 下方整列上移补位，用户第二根手指几十毫秒后落回原位置时那里已经是 App 画面了。
static BOOL AevonGuardDockHitTest(CGPoint pt) {
    @try {
        CFTimeInterval now = CACurrentMediaTime();
        if (now < gAevonDockGhostUntil && !CGRectIsEmpty(gAevonDockGhost)
            && CGRectContainsPoint(gAevonDockGhost, pt)) {
            return YES;
        }
        NSUInteger right = 0, left = 0;
        if (AevonGuardDockCounts(&right, &left) == 0) { return NO; }
        if (gAevonDockW < 1.0) { AevonGuardDockMetrics(); }
        if (gAevonDockW < 1.0) { return NO; }
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        const CGFloat slop = 3.0;
        for (NSUInteger side = 0; side < 2; side++) {
            NSUInteger count = (side == 0) ? right : left;
            CGFloat originX = (side == 0) ? (sw - gAevonDockW) : 0;
            for (NSUInteger i = 0; i < count; i++) {
                CGRect r = CGRectMake(originX, gAevonDockTop + (CGFloat)i * gAevonDockStep,
                                      gAevonDockW, gAevonDockH);
                if (CGRectContainsPoint(CGRectInset(r, -slop, -slop), pt)) {
                    gAevonDockGhost = CGRectInset(r, -slop, -slop);
                    gAevonDockGhostUntil = now + 1.0;
                    return YES;
                }
            }
        }
    } @catch (NSException *exception) {
        return NO;
    }
    return NO;
}

/* V0.0.56（AevonGuardFloatRectV56）：主悬浮窗矩形吞摸。
 *
 * Aevon(50) 第 2 / 5 条：全屏 App 里双击浮窗底边关闭、快速连点停靠小窗切换主窗，
 * 都会让 App 吃到一次点击。已有两条判据都不够：
 *   · bit48 是「按下写、抬手 350ms 后清」——双击间隔 0.36s，第二下正好落在放行之后；
 *   · 停靠格几何只覆盖停靠态，主窗本体没有任何判据。
 * 主窗（含外侧手势区）的矩形是**确定**的，SB 一变几何就写进共享内存，
 * 落在这块屏幕上的触摸一律吞 —— 浮窗盖住的地方本来就不该让 App 收到输入。 */
/// 主悬浮窗矩形（含外侧手势区），由 SpringBoard 写入 `com.aevon.guardfloat`。
static CGRect AevonGuardFloatRectRect(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.guardfloat", &token);
    });
    if (token < 0) { return CGRectZero; }
    uint64_t pack = 0;
    notify_get_state(token, &pack);
    uint64_t ver = (pack >> 48) & 0xFFULL;
    if (ver != 0x36ULL) { return CGRectZero; }
    if (((pack >> 40) & 1ULL) == 0) { return CGRectZero; }
    CGFloat x = (CGFloat)(pack & 0x3FFULL);
    CGFloat y = (CGFloat)((pack >> 10) & 0x3FFULL);
    CGFloat w = (CGFloat)((pack >> 20) & 0x3FFULL);
    CGFloat h = (CGFloat)((pack >> 30) & 0x3FFULL);
    if (w < 1 || h < 1) { return CGRectZero; }
    return CGRectMake(x, y, w, h);
}

/// 停靠小窗「刚被点走」留下的幽灵格 —— 变量定义已上移到 AevonGuardDockHitTest 之前。

/* V0.0.57（AevonNoWinResizeV57）：App 窗口尺寸 —— **只允许单向还原**。
 *
 * Aevon(50) 第 4 条当时以为是「App 窗口没跟着浮窗缩小」，于是在 App 进程里改
 * keyWindow.frame。Aevon(51) 证明这条路更糟：
 *   · 第 1 条：内容依旧放大 / 剪裁 / 排列错乱 —— 抖音这类 App 按 `UIScreen` 排版，
 *     窗口变小只是把内容裁掉一块，布局不会真的重排；
 *   · 第 4 条：关窗后小窗口残留 → 回到桌面再全屏打开应用，大面积黑屏。
 * 所以这里不再缩小任何窗口，只保留「还原整屏」的兜底（修上一版可能留下的残局，
 * 以及任何被别的东西改小的窗口）。真正的显示适配在 SpringBoard 侧做：
 * 整屏画面等比完整缩放（AevonContentFitV57）。 */
static BOOL gAevonWindowKeptFullLogged = NO;

static void AevonGuardKeepWindowFull(void) {
    @try {
        static CFTimeInterval lastAt = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastAt < 1.0) { return; }
        lastAt = now;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIApplication *app = [UIApplication sharedApplication];
        NSArray<UIWindow *> *wins = (app != nil) ? app.windows : nil;
        UIWindow *win = nil;
        for (UIWindow *candidate in wins) {
            if (candidate.isKeyWindow) { win = candidate; break; }
        }
        if (win == nil) { win = wins.firstObject; }
        if (win == nil) { return; }
        CGRect screen = [UIScreen mainScreen].bounds;
        if (CGRectEqualToRect(win.frame, screen)) { return; }
        win.frame = screen;
        [win.rootViewController.view setNeedsLayout];
        [win.rootViewController.view layoutIfNeeded];
        if (!gAevonWindowKeptFullLogged) {
            gAevonWindowKeptFullLogged = YES;
            AevonGuardWriteLog(YES, @"App 窗口曾被改小，已还原成整屏"
                               @"（本版不再改窗口尺寸：内容适配改由浮窗侧等比整屏缩放负责）"
                               @"（AevonNoWinResizeV57）");
        }
#pragma clang diagnostic pop
    } @catch (NSException *exception) {
    }
}

/* V0.0.35（AevonGuardAckV35）：ack 回执。
 * 沙盒 App 写不了 /var/mobile/Aevon.log（V0.0.34 的 Guard 日志在抖音里全部失败，
 * Aevon(28) 日志零 [Guard] 行），改用 notify_post 回执：Guard 读到圆盘状态 /
 * 收到 ringopen 时 post com.aevon.guardack，SpringBoard 监听并写日志 ——
 * 下一版日志能直接确证「Guard 注入了 + state 读到了」。notify_post 走 notifyd，
 * 沙盒 App 可用。 */
static void AevonGuardPostAck(void) {
    @try {
        notify_post("com.aevon.guardack");
    } @catch (NSException *exception) {
    }
}

#pragma mark - 日志（V0.0.34，AevonGuardLogV34）

/* Guard 自己写 /var/mobile/Aevon.log（与 SpringBoard 侧 AevonLog 同一文件）。
 * 目的：下一版日志能直接看到「Guard 注入了哪些进程、圆盘状态何时翻转、吞了多少事件」，
 * 不再两眼一抹黑。写入限频（非 force 每秒最多 1 条），ring 状态切换 / 安装时 force。 */
static void AevonGuardWriteLog(BOOL force, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void AevonGuardWriteLog(BOOL force, NSString *fmt, ...) {
    @try {
        static CFTimeInterval lastAt = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (!force && (now - lastAt) < 1.0) { return; }
        lastAt = now;

        static NSDateFormatter *formatter = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
            formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        });

        va_list args;
        va_start(args, fmt);
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);

        NSString *line = [NSString stringWithFormat:@"[%@] [信息] [Guard] %@\n",
                          [formatter stringFromDate:[NSDate date]], body];
        const char *utf8 = line.UTF8String;
        if (utf8 == NULL) { return; }
        FILE *f = fopen("/var/mobile/Aevon.log", "a");
        if (f == NULL) { return; }
        fwrite(utf8, 1, strlen(utf8), f);
        fclose(f);
    } @catch (NSException *exception) {
        // 日志失败绝不影响 App
    }
}

#pragma mark - 偏好读取

static CFStringRef AevonGuardKey(const char *utf8) {
    return CFStringCreateWithCString(kCFAllocatorDefault, utf8, kCFStringEncodingUTF8);
}

static BOOL AevonGuardPrefBool(const char *key, BOOL fallback) {
    CFStringRef k = AevonGuardKey(key);
    if (k == NULL) return fallback;
    Boolean exists = false;
    Boolean value = CFPreferencesGetAppBooleanValue(k, AevonGuardDomain, &exists);
    CFRelease(k);
    return exists ? (BOOL)value : fallback;
}

static double AevonGuardPrefDouble(const char *key, double fallback, double lo, double hi) {
    CFStringRef k = AevonGuardKey(key);
    if (k == NULL) return fallback;
    CFPropertyListRef raw = CFPreferencesCopyAppValue(k, AevonGuardDomain);
    CFRelease(k);

    double value = fallback;
    if (raw != NULL) {
        CFTypeID type = CFGetTypeID(raw);
        if (type == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)raw, kCFNumberDoubleType, &value);
        } else if (type == CFStringGetTypeID()) {
            value = CFStringGetDoubleValue((CFStringRef)raw);
        }
        CFRelease(raw);
    }
    if (value < lo) value = lo;
    if (value > hi) value = hi;
    return value;
}

/// 与 SpringBoard 侧 `AevonTriggerZone.rect(in:)` 完全一致的几何计算
///
/// V0.0.32（AevonGuardNotifyV32）：配置来源优先级
///   1. notify(3) 状态（跨进程、沙盒通用，主通道）
///   2. guard.conf 文件（多路径兜底）
///   3. 偏好域（仅非沙盒进程）
///   4. 默认几何 + PluginAlive 插存（收到过 ringopen 就证明插件开着）
/// 沙盒 App（抖音 / QQ）里 CFPreferences 读 com.Aevon 会被重定向进自己的容器；
/// guard.conf 也可能因 SpringBoard 写不进 root 属主目录而失败（Aevon(25)）。
static BOOL AevonGuardReadConfFile(CGRect *outZone, BOOL *outEnabled) {
    const char *paths[] = {
        "/var/jb/Library/Aevon/guard.conf",
        "/var/jb/Library/PreferenceBundles/AevonPrefs.bundle/guard.conf",
        "/Library/Aevon/guard.conf",
        "/Library/PreferenceBundles/AevonPrefs.bundle/guard.conf",
        "/var/mobile/AevonGuard.conf",
    };
    for (int i = 0; i < 5; i++) {
        FILE *f = fopen(paths[i], "r");
        if (f == NULL) { continue; }
        char marker[64];
        char values[160];
        BOOL ok = (fgets(marker, sizeof(marker), f) != NULL)
            && (strstr(marker, "AEVONGUARDCONF") != NULL)
            && (fgets(values, sizeof(values), f) != NULL);
        fclose(f);
        if (!ok) { continue; }
        double x = 0, y = 0, w = 0, h = 0;
        int enabled = 0;
        if (sscanf(values, "%lf %lf %lf %lf %d", &x, &y, &w, &h, &enabled) == 5) {
            if (w >= 1 && h >= 1) {
                *outZone = CGRectMake(x, y, w, h);
                *outEnabled = enabled ? YES : NO;
                return YES;
            }
        }
    }
    return NO;
}

/* V0.0.34：读 notify(3) 状态通道（与 SpringBoard 侧打包格式一致）。
 * AevonGuard 是独立 dylib，不链接 AevonAssertionShim，所以这里自带一份解包。
 * 格式：x:10 y:10 w:8 h:10 enabled:1 ring:1(bit39) 版本:8（0x34 = V34）。
 * 注意：notify_set_state / notify_get_state 参数是 **int token**，不是名字！ */
static int AevonGuardNotifyToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.guardzone", &token);
    });
    return token;
}

static BOOL AevonGuardReadNotifyZone(CGRect *outZone, BOOL *outEnabled) {
    int token = AevonGuardNotifyToken();
    if (token < 0) { return NO; }
    uint64_t pack = 0;
    notify_get_state(token, &pack);
    /* 读失败时 pack 保持 0，版本标记对不上就当没有配置。
     * V0.0.56：0x36 也必须认（SB 从 V54 起就写 0x36，旧白名单只到 0x35，
     * 导致热区配置一直退回 guard.conf 文件通道）。 */
    uint64_t ver = (pack >> 40) & 0xFFULL;
    if (ver != 0x34ULL && ver != 0x35ULL && ver != 0x36ULL) { return NO; }
    double x = (double)(pack & 0x3FFULL);
    double y = (double)((pack >> 10) & 0x3FFULL);
    double w = (double)((pack >> 20) & 0xFFULL);
    double h = (double)((pack >> 28) & 0x3FFULL);
    if (w < 1 || h < 1) { return NO; }
    *outZone = CGRectMake(x, y, w, h);
    *outEnabled = ((pack >> 38) & 1ULL) ? YES : NO;
    return YES;
}

static void AevonGuardReloadConfig(void) {
    AevonGuardConfigAt = CACurrentMediaTime();

    CGRect zone = CGRectZero;
    BOOL enabled = NO;

    /* 1. notify(3) 状态通道（主通道，沙盒通用） */
    if (AevonGuardReadNotifyZone(&zone, &enabled)) {
        AevonGuardEnabled = enabled;
        AevonGuardZone = enabled ? zone : CGRectZero;
        return;
    }

    /* 2. guard.conf 文件通道 */
    if (AevonGuardReadConfFile(&zone, &enabled)) {
        AevonGuardEnabled = enabled;
        AevonGuardZone = enabled ? zone : CGRectZero;
        return;
    }

    /* 3. 偏好域（仅对非沙盒进程有意义）。语义与 SB 一致的「底边锚定」。 */
    BOOL prefOn = AevonGuardPrefBool("Enabled", NO);
    BOOL edge = AevonGuardPrefBool("EdgeGestureEnabled", YES);
    AevonGuardEnabled = (prefOn && edge);
    if (AevonGuardEnabled) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (bounds.size.width >= 1.0 && bounds.size.height >= 1.0) {
            double ratio = AevonGuardPrefDouble("RingTriggerY", 75.0, 0.0, 100.0) / 100.0;
            double rawWidth = AevonGuardPrefDouble("RingTriggerWidth", 48.0, 18.0, 140.0);
            double rawHeight = AevonGuardPrefDouble("RingTriggerHeight", 320.0, 80.0, 900.0);
            CGFloat width = MIN(rawWidth, bounds.size.width);
            CGFloat height = MIN(rawHeight, bounds.size.height);
            CGFloat bottomY = bounds.size.height * ratio;
            CGFloat y = MIN(MAX(bottomY - height, 0.0), bounds.size.height - height);
            AevonGuardZone = CGRectMake(bounds.size.width - width, y, width, height);
            return;
        }
    }

    /* 4. V0.0.32：三路全失败，但收到过 ringopen —— 插件肯定开着，用默认几何兜底 */
    if (AevonGuardPluginAlive) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (bounds.size.width >= 1.0 && bounds.size.height >= 1.0) {
            CGFloat width = MIN(48.0, bounds.size.width);
            CGFloat height = MIN(320.0, bounds.size.height);
            CGFloat bottomY = bounds.size.height * 0.75;
            CGFloat y = MIN(MAX(bottomY - height, 0.0), bounds.size.height - height);
            AevonGuardEnabled = YES;
            AevonGuardZone = CGRectMake(bounds.size.width - width, y, width, height);
            return;
        }
    }

    AevonGuardEnabled = NO;
    AevonGuardZone = CGRectZero;
}

#pragma mark - 事件拦截

/*
 * 判定与投递规则（与 SpringBoard 侧 `AevonEdgeEntry.shouldSwallowGlobalTouch` 同语义）：
 *   · 某个触摸在 `Began` 时落在热区 → 记入「已接管集合」，从这一帧起它的所有事件都不投递；
 *   · 该触摸 `Ended` / `Cancelled` 时判定完再移出集合（保证抬手那一帧也吞掉）；
 *   · 只有**整条事件里所有活动触摸都被接管**时才整条丢弃 —— 混进别的手指就整体照常投递，
 *     绝不因为用户在热区按了一下就把另一根手指的输入也吃掉。
 */
/* V0.0.56（AevonGuardTouchMarkV56）：触摸接管标记改用 associated object。
 *
 * Aevon(50) 第 3 条（严重）：「插件会导致屏幕部分位置无法点击，全屏幕操作失效」。
 *
 * 根因就在旧实现 —— 它用 **UITouch 对象指针** 当 `CFMutableSet` 的 key：
 *   CFSetAddValue(swallowed, (__bridge const void *)touch)
 * UITouch 由 UIKit 池化复用，一次触摸结束、对象释放后，**同一个地址会被下一根手指复用**。
 * 只要有一条触摸没走到 Ended/Cancelled（系统打断、进程切场景、手指滑出屏幕），
 * 它的地址就永久留在集合里 —— 之后任何一个复用到该地址的新触摸，began 时
 * `CFSetContainsValue` 命中，被当成「已接管的旧手指」直接吞掉。
 * 表现正是「某些位置突然点不动，且越用越严重」，重启 App 才好。
 *
 * 关联对象挂在 UITouch 自身生命周期上：对象销毁 → 标记一起销毁，地址复用不会误判。
 * 顺便把「热区」从「按下即吞」改成「移动超过阈值才吞」—— 见 sendEvent 里的注释。
 */
static const void *AevonGuardTouchOwnKey = &AevonGuardTouchOwnKey;
static const void *AevonGuardTouchStartKey = &AevonGuardTouchStartKey;

static BOOL AevonGuardTouchOwned(UITouch *touch) {
    id value = objc_getAssociatedObject(touch, AevonGuardTouchOwnKey);
    return value != nil;
}

static void AevonGuardSetTouchOwned(UITouch *touch, BOOL owned) {
    objc_setAssociatedObject(touch, AevonGuardTouchOwnKey,
                             owned ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void AevonGuardSetTouchStart(UITouch *touch, CGPoint point) {
    objc_setAssociatedObject(touch, AevonGuardTouchStartKey,
                             [NSValue valueWithCGPoint:point],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL AevonGuardGetTouchStart(UITouch *touch, CGPoint *outPoint) {
    NSValue *value = objc_getAssociatedObject(touch, AevonGuardTouchStartKey);
    if (value == nil) { return NO; }
    if (outPoint) { *outPoint = value.CGPointValue; }
    return YES;
}

static void AevonGuardCallOriginal(id self, SEL _cmd, UIEvent *event) {
    if (AevonGuardOrigSendEvent == NULL) { return; }
    ((void (*)(id, SEL, UIEvent *))AevonGuardOrigSendEvent)(self, _cmd, event);
}

static void AevonGuardSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (AevonGuardOrigSendEvent == NULL) {
        return;
    }
    // 先判断配置是否过期（构造函数里不读 UIScreen，首次 sendEvent 时才加载）
    if (CACurrentMediaTime() - AevonGuardConfigAt > AevonGuardConfigTTL) {
        AevonGuardReloadConfig();
    }
    /* V0.0.32：圆盘展开期的下半屏吞触摸**不再依赖 Enabled / 配置**。
     * Aevon(25)：guard.conf 写不进 → 配置全空 → Enabled 恒 false →
     * 连圆盘展开保护也整条失效，抖音被暂停 / 圆盘滑动带动全屏 App。
     * 只要收到过 ringopen（通知本身不依赖任何配置），下半屏一律吞。 */
    /* V0.0.34：圆盘状态翻转时打一条日志（force，不受限频）——
     * 下一版日志能直接确认「Guard 看到了圆盘开 / 关」，不再靠猜。 */
    BOOL ringOpen = AevonGuardRingOpen();
    /* V0.0.49：浮窗手势期（SpringBoard 写 bit48）—— 手指正压在浮窗上，
     * App 进程这一份事件也必须吞掉，否则轻点会合成一次 App 内点击。 */
    BOOL floatTouch = AevonGuardFloatTouch();
    /* V0.0.54（AevonGuardDockZoneV54）：停靠列**几何**通道，与触摸时序无关 ——
     * 只要那一格停着一个小窗，落在它上面的触摸一律吞，快速连点也不会漏。 */
    BOOL docked = (AevonGuardDockCounts(NULL, NULL) > 0);
    /* V0.0.56（AevonGuardFloatRectV56）：主悬浮窗矩形 —— 浮窗盖住的那块屏幕，
     * App 一律收不到输入（双击底边 / 快速连点都不会漏）。 */
    CGRect floatRect = AevonGuardFloatRectRect();
    BOOL hasFloatRect = !CGRectIsEmpty(floatRect);
    /* V0.0.57（AevonNoWinResizeV57）：**不再改 App 的窗口尺寸**。
     *
     * Aevon(51) 第 1 条（内容被放大 / 剪裁 / 排列错乱）与第 4 条（关窗后全屏打开
     * 大面积黑屏）都是这条通道造成的：改 keyWindow.frame 让 App 真的变成 267x458，
     * 抖音这类按 UIScreen 排版的 App 内部布局仍然错乱；关窗时窗口尺寸没被可靠还原，
     * 回到桌面再全屏打开就是一块小窗 + 大片黑。
     * 内容显示改由 SpringBoard 侧「整屏等比完整缩放」负责，这里只在 App 进后台 /
     * 回前台时把窗口**单向**还原成整屏（修上一版可能残留的小窗口）。 */
    AevonGuardKeepWindowFull();
    {
        static BOOL lastLogged = NO;
        static BOOL hasLogged = NO;
        if (!hasLogged || ringOpen != lastLogged) {
            hasLogged = YES;
            lastLogged = ringOpen;
            AevonGuardPostAck();   /* V0.0.35：状态翻转回执（SB 侧写日志确证） */
            AevonGuardWriteLog(YES, @"圆盘状态 → %@（%@）",
                               ringOpen ? @"展开" : @"收起",
                               AevonGuardEnabled ? @"热区拦截启用" : @"仅圆盘期拦截");
        }
    }
    if (!AevonGuardEnabled && !ringOpen && !floatTouch && !docked && !hasFloatRect) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }
    if (event == nil) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }
    if (!ringOpen && !floatTouch && !docked && !hasFloatRect && CGRectIsEmpty(AevonGuardZone)) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }

    NSSet *touches = [event allTouches];
    if (touches.count == 0) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }

    NSUInteger active = 0;
    NSUInteger swallowed = 0;
    for (UITouch *touch in touches) {
        UITouchPhase phase = [touch phase];
        if (phase == UITouchPhaseStationary) { continue; }
        active += 1;

        BOOL owned = AevonGuardTouchOwned(touch);

        if (phase == UITouchPhaseBegan) {
            CGPoint pt = [touch locationInView:nil];
            BOOL hardZone = NO;
            /* V0.0.67（AevonGuardGhostRecordV67）：停靠格几何命中**先跑，且无论后面
             * 哪条判据吞掉这一触摸都照跑**。
             *
             * 这是「轻点停靠小窗还原主窗 → App 内被点一下」多版本反复出现的真正根因：
             * 旧实现是 else-if 链 —— bit48（浮窗手势期）先命中时 DockHitTest 根本不执行，
             * 「幽灵格」从未被记下；而轻点还原时 SB 会在触摸刚结束就把停靠格几何位清零、
             * bit48 又在 350ms 后放行 —— 原槽位从此零保护，用户连点的第二击直达
             * App 画面合成一次点击。现在先跑几何命中（命中即记幽灵格，含 1 秒续期），
             * 再用结果进判定链，两条吞摸路径互不遮挡。 */
            BOOL dockHit = AevonGuardDockHitTest(pt);
            if (floatTouch) {
                /* V0.0.49：浮窗手势期 —— 整屏吞。手指压在浮窗上时，
                 * App 不该收到任何输入（这是「点小窗还原 → 抖音暂停」的正面修法）。 */
                hardZone = YES;
            } else if (ringOpen) {
                /* V0.0.35：圆盘开着 —— **整屏**吞掉（连顶部 18% 也吞，状态栏区无交互需求）。
                 * 旧版留 18% 是给「万一圆盘需要顶部交互」，实际不存在这个场景，
                 * 反而多留一条缝。图标选择 / 旋转走 SpringBoard 全局通道副本，不依赖这里投递。 */
                hardZone = YES;
            } else if (hasFloatRect && CGRectContainsPoint(floatRect, pt)) {
                /* V0.0.56：落在主悬浮窗（含外侧手势区）上 —— 这块屏幕本来就被浮窗盖着，
                 * App 不该收到任何输入。双击的第二下（间隔 0.36s > bit48 的 350ms 放行）
                 * 就靠这条判据兜住。 */
                hardZone = YES;
            } else if (dockHit) {
                /* V0.0.54：落在某一格停靠小窗上 —— 这本来就是浮窗自己的那块屏幕，
                 * App 不该收到任何输入（点它 = 还原主窗，不是点 App）。 */
                hardZone = YES;
                static NSUInteger dockSwallowCount = 0;
                dockSwallowCount += 1;
                if (dockSwallowCount % 20 == 1) {
                    AevonGuardWriteLog(NO, @"停靠小窗区域拦下触摸（累计 %lu 次）",
                                       (unsigned long)dockSwallowCount);
                }
            }
            if (hardZone) {
                AevonGuardSetTouchOwned(touch, YES);
                owned = YES;
            } else if (!CGRectIsEmpty(AevonGuardZone)
                       && CGRectContainsPoint(AevonGuardZone, pt)) {
                /* V0.0.56：**热区改为「移动才吞」**。
                 *
                 * 热区（屏幕右边缘 18pt 宽、底边往上 258pt）是呼出圆盘用的，
                 * 触发条件是「左滑 ≥ 30pt」——纯点击根本不该被吞。
                 * 但旧实现 began 就无条件吞，于是这条 18pt 竖条上的 App 按钮
                 * （抖音右侧工具栏最后几个正好压在 x≈412~430）永远点不动，
                 * 用户 Aevon(50) 第 3 条「屏幕部分位置无法点击」的另一半就是它。
                 * 现在只记起点、先放行；真正出现横向拖动（> 8pt）才接管，
                 * 手势照样呼得出圆盘，纯点击则完整交给 App。 */
                AevonGuardSetTouchStart(touch, pt);
            }
        } else if (phase == UITouchPhaseMoved && !owned) {
            CGPoint start;
            if (AevonGuardGetTouchStart(touch, &start)) {
                CGPoint now = [touch locationInView:nil];
                CGFloat dx = now.x - start.x;
                CGFloat dy = now.y - start.y;
                /* 只有「往左划」才接管 —— 那才是呼出圆盘的手势（SB 侧判据：左滑 ≥30pt）。
                 * 纯点击、竖向滚动（抖音右侧上下滑）、向右划一律放行，
                 * App 拿到的是完整触摸序列，不会出现「按钮点不动」或「滑到一半断掉」。 */
                if (dx < -8.0 && fabs(dx) >= fabs(dy)) {
                    AevonGuardSetTouchOwned(touch, YES);
                    owned = YES;
                }
            }
        }

        if (owned) {
            swallowed += 1;
            if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
                AevonGuardSetTouchOwned(touch, NO);
            }
        }
    }

    if (active > 0 && swallowed == active) {
        /* V0.0.34：吞摸计数（每 40 条打一次，限频内），下一版日志可量化拦截效果 */
        static NSUInteger swallowCount = 0;
        swallowCount += 1;
        if (swallowCount % 40 == 1) {
            AevonGuardWriteLog(NO, @"已吞触摸事件（累计 %lu 条）", (unsigned long)swallowCount);
        }
        return;   // 整条事件丢弃
    }
    AevonGuardCallOriginal(self, _cmd, event);
}

#pragma mark - 安装

static void AevonGuardPrefsChanged(CFNotificationCenterRef center,
                                   void *observer,
                                   CFNotificationName name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    // 让下一次 sendEvent 重新读配置
    AevonGuardConfigAt = 0;
}

/* V0.0.29：圆盘开 / 关广播（SpringBoard 侧 AevonEdgeEntry 发出） */
static void AevonGuardRingOpened(CFNotificationCenterRef center,
                                 void *observer,
                                 CFNotificationName name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    AevonGuardRingOpenAt = CACurrentMediaTime();
    /* V0.0.32：收到 ringopen = 插件肯定在跑。立刻重读配置；
     * 之后即使配置读不到也用默认几何兜底，不再整条 Guard 失效。 */
    AevonGuardPluginAlive = YES;
    AevonGuardConfigAt = 0;
    AevonGuardPostAck();   /* V0.0.35 */
}

static void AevonGuardRingClosed(CFNotificationCenterRef center,
                                 void *observer,
                                 CFNotificationName name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    AevonGuardRingOpenAt = 0;
}

static void AevonGuardInstall(void) {
    if (AevonGuardOrigSendEvent != NULL) { return; }

    Class applicationClass = objc_getClass("UIApplication");
    if (applicationClass == Nil) { return; }
    Method method = class_getInstanceMethod(applicationClass, sel_registerName("sendEvent:"));
    if (method == NULL) { return; }

    // 构造函数阶段不读 UIScreen / 偏好，等第一次 sendEvent 再加载（主线程、UIKit 已就绪）
    AevonGuardConfigAt = 0;
    AevonGuardOrigSendEvent = method_setImplementation(method, (IMP)AevonGuardSendEvent);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonGuardPrefsChanged,
                                    CFSTR("com.aevon.prefschanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonGuardRingOpened,
                                    CFSTR("com.aevon.ringopen"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonGuardRingClosed,
                                    CFSTR("com.aevon.ringclose"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    /* V0.0.32：notify(3) 状态写入时 SpringBoard 会 post com.aevon.prefschanged，
     * 上面的 prefschanged 观察者已把 ConfigAt 清零 → 下一次 sendEvent 重读 notify 状态。
     * 不额外 register notify 回调，避免 blocks / dispatch 依赖。 */

    /* V0.0.57（AevonNoWinResizeV57）：单向兜底 —— 进后台 / 回前台都把窗口还原成整屏。
     *
     * Aevon(51) 第 4 条：「双击关闭浮窗后，回桌面再全屏打开应用会出现大面积黑屏」。
     * 根因是上一版在 App 进程里把 keyWindow 改小了、关窗时又没可靠还原。
     * 本版不再缩小窗口；两个通知都做一次「只放大不缩小」的校正，
     * 顺带修掉上一版可能残留在现场的 267x458 小窗口。 */
    for (NSString *name in @[UIApplicationDidEnterBackgroundNotification,
                             UIApplicationWillEnterForegroundNotification,
                             UIApplicationDidBecomeActiveNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
            AevonGuardKeepWindowFull();
        }];
    }

    NSLog(@"[Aevon] App 侧热区拦截已安装（%s %s）", AevonAppGuardMarker, AevonGuardNotifyMarker);
    /* V0.0.34（AevonGuardLogV34）：注入确认日志 —— 用户日志里出现这行就说明 Guard 真的进了这个 App */
    AevonGuardWriteLog(YES, @"已注入进程 %@（bundle %@），sendEvent 拦截就绪（AevonGuardStateRingV34 AevonGuardLogV34 AevonGuardRingExactV37）",
                       [NSString stringWithUTF8String:getprogname() ?: "?"],
                       [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
}

__attribute__((constructor)) static void AevonGuardConstructor(void) {
    @autoreleasepool {
        const char *process = getprogname();
        // SpringBoard 由 Aevon.dylib 负责；这里只管前台 App
        if (process != NULL && strcmp(process, "SpringBoard") == 0) { return; }
        // 没有 UIKit 的进程（守护进程 / launchd / backboardd）直接退出，绝不做任何事
        if (objc_getClass("UIApplication") == NULL) { return; }
        if (objc_getClass("SpringBoard") != NULL) { return; }
        /*
         * V0.0.62（AevonGuardNoExtV61）：**UIApplication 实例不存在 = headless 进程**。
         * 小组件/键盘等扩展进程链接 UIKit（类存在），但永远没有 sharedApplication 实例；
         * V61 的 NSExtension/.appex 检查（按 bundle 信息判断）之外再加这层运行时保险：
         * headless 环境绝不装 sendEvent 拦截 —— 修「桌面部分小组件空白」。
         */
        if ([UIApplication sharedApplication] == nil) { return; }
        /*
         * V0.0.28：**排除「设置」App**。
         * 设置页里的三个触发区滑杆跨在热区里，若在 Preferences 进程也被接管，
         * 滑杆右半截就拖不动（用户会以为「滑条只能拖到最小值」）。
         * Aevon 自己的设置页永远不需要热区手势。
         */
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.Preferences"]) { return; }

        /*
         * V0.0.61（AevonGuardNoExtV61）：**扩展进程（.appex）绝不装 Guard**。
         * 用户反馈「最近几个版本桌面部分小程序不显示（位置空白）」：
         * 小组件/键盘等扩展进程也链接 UIKit，会命中 com.apple.UIKit 注入过滤器；
         * Guard 在扩展的头less 环境里装 sendEvent 拦截 + 生命周期监听，
         * 扩展一崩它的桌面小组件就是一块空白 —— 正好是「部分小程序不显示」
         * （只有崩了的那些扩展对应的小组件空白）。主 App 没有 NSExtension 键，
         * 此判断不会误伤。
         */
        NSDictionary *guardInfo = [[NSBundle mainBundle] infoDictionary];
        if (guardInfo[@"NSExtension"] != nil) { return; }
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        if ([bundlePath hasSuffix:@".appex"]) { return; }

        @try {
            AevonGuardInstall();
        } @catch (NSException *exception) {
            // 任何异常都不允许影响 App 启动
        }
    }
}
