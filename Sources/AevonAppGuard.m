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
/// CI 标记（V0.0.80）：小组件宿主（Chrono / WidgetKit）也不装 Guard —— Aevon(72) 第 3 条
__attribute__((used)) static const char AevonGuardNoWidgetV80Marker[] = "AevonGuardNoWidgetV80";
/// CI 标记（V0.0.80）：不再强行放大 App 窗口（旧实现每秒改 frame + layoutIfNeeded，
/// 会吃掉整屏触摸、把内容拽得自己上滑）
__attribute__((used)) static const char AevonNoWinResizeV80Marker[] = "AevonNoWinResizeV80";
__attribute__((used)) static const char AevonGuardGhostRecordV67Marker[] = "AevonGuardGhostRecordV67";
/// CI 标记（V0.0.68）：「设置」App 解除整体排除（装 Guard、热区禁用）+ 注入自检日志
__attribute__((used)) static const char AevonGuardPrefsAliveV68Marker[] = "AevonGuardPrefsAliveV68";
__attribute__((used)) static const char AevonGuardLateStartV69Marker[] = "AevonGuardLateStartV69";
__attribute__((used)) static const char AevonGuardGhostWideV70Marker[] = "AevonGuardGhostWideV70";
/// CI 标记（V0.0.71）：moved/ended 晚到重判 —— began 竞态泄漏的短触摸回收
__attribute__((used)) static const char AevonGuardLateRejudgeV71Marker[] = "AevonGuardLateRejudgeV71";
/// CI 标记（V0.0.72）：幽灵格自动记录 + began 放行取证 + 版本日志
__attribute__((used)) static const char AevonGuardGhostAutoV72Marker[] = "AevonGuardGhostAutoV72";
__attribute__((used)) static const char AevonGuardScreenPtV73Marker[] = "AevonGuardScreenPtV73";
__attribute__((used)) static const char AevonGuardTapStampV74Marker[] = "AevonGuardTapStampV74";
/// CI 标记（V0.0.81）：整窗触摸门（坐标无关）+ 浮窗手势误滚还原
__attribute__((used)) static const char AevonAppGateV81Marker[] = "AevonAppGateV81";
__attribute__((used)) static const char AevonScrollLeakV81Marker[] = "AevonScrollLeakV81";

static CFStringRef const AevonGuardDomain = CFSTR("com.Aevon");
static IMP AevonGuardOrigSendEvent = NULL;
static BOOL AevonGuardEnabled = NO;
static CGRect AevonGuardZone = {{0, 0}, {0, 0}};
/* V0.0.68（AevonGuardPrefsAliveV68）：「设置」App 专用的热区禁用标志。
 *
 * V0.0.28 起 Guard 整体排除 com.apple.Preferences —— 当时热区是「began 无条件吞」，
 * 设置页滑杆跨在热区里向左拖会被吞，只好整个不装。但这留下了大洞：
 * 用户拿「设置」App 浮窗测试时（com.apple.Preferences 正是前台），停靠小窗的
 * 触摸在 App 进程里无人吞 —— 轻点还原合成一次 App 内点击（穿透），多版本反复。
 * V56 之后热区已改「移动才吞 + 只吞向左滑」，但向左拖滑杆仍会被吞，
 * 所以不能简单去掉排除 —— 改为：**照常装 Guard，只是热区恒空**。
 * 浮窗判据（停靠格几何 / 主窗矩形 / bit48 / 圆盘期）全部保留 ——
 * 这些都以「浮窗状态激活」为前提，不会碰设置页的滑杆。 */
static BOOL gAevonGuardPrefsNoZone = NO;
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
/// 在窗口期内继续吞摸（同一只手连点 5 个也不会漏）。
///
/// V0.0.70（AevonGuardGhostWideV70）：单格 → 最多 8 格数组 + 1s → 2s。
/// 单格实现的洞：点走 A 格后立刻点 B 格，B 的幽灵覆盖 A —— A 位置漏保护；
/// 1s 时长在「还原 → 自动停靠旧主窗 → 再还原」的快速循环里也不够
/// （Aevon(63) 日志连点间隔 ~0.5s，第 3 击起幽灵已过期，全靠 bit48 竞态兜底）。
static CGRect gAevonDockGhosts[8];
static CFTimeInterval gAevonDockGhostUntil[8];
static NSInteger gAevonDockGhostCount = 0;

/* V0.0.72（AevonGuardGhostAutoV72）：幽灵格**自动记录** —— SB 侧无从告知
 * 「哪一格刚被点走」，但 Guard 自己观察 bit50~55 的数量变化就够了：
 * 停靠数减少 = 有小窗离开槽位（轻点还原 / 自动吸附），把被移除的那几格
 * 矩形记入幽灵表 2s。与触摸时序完全无关（状态位是确定事件），
 * 补上「began 竞态失败 + 命中格已从几何位移除」的最后一类漏网。 */
static NSUInteger gAevonDockLastRight = 0;
static NSUInteger gAevonDockLastLeft = 0;
static BOOL gAevonDockLastValid = NO;

static void AevonGuardDockGhostAdd(CGRect rect, CFTimeInterval now) {
    NSInteger slot = -1;
    for (NSInteger gi = 0; gi < gAevonDockGhostCount; gi++) {
        if (CGRectEqualToRect(gAevonDockGhosts[gi], rect)) { slot = gi; break; }
    }
    if (slot < 0) {
        if (gAevonDockGhostCount < 8) {
            slot = gAevonDockGhostCount++;
        } else {
            slot = 0;
            for (NSInteger gi = 1; gi < 8; gi++) {
                if (gAevonDockGhostUntil[gi] < gAevonDockGhostUntil[slot]) { slot = gi; }
            }
        }
        gAevonDockGhosts[slot] = rect;
    }
    gAevonDockGhostUntil[slot] = now + 2.0;
}

static void AevonGuardDockGhostAutoRecord(void) {
    @try {
        NSUInteger right = 0, left = 0;
        NSUInteger total = AevonGuardDockCounts(&right, &left);
        if (!gAevonDockLastValid) {
            if (total > 0) {
                gAevonDockLastRight = right;
                gAevonDockLastLeft = left;
                gAevonDockLastValid = YES;
            }
            return;
        }
        if (right == gAevonDockLastRight && left == gAevonDockLastLeft) { return; }
        /* 只记「减少」：增加（新停靠）不需要幽灵格 */
        if (right < gAevonDockLastRight || left < gAevonDockLastLeft) {
            if (gAevonDockW < 1.0) { AevonGuardDockMetrics(); }
            if (gAevonDockW >= 1.0) {
                CGFloat sw = [UIScreen mainScreen].bounds.size.width;
                const CGFloat slop = 3.0;
                CFTimeInterval now = CACurrentMediaTime();
                /* 补位上移的语义：被点走的那格内容已离开，剩余格整体上移补位，
                 * 所以「消失的位置」= 原列尾（i >= 新数量）的那几格。 */
                for (NSUInteger side = 0; side < 2; side++) {
                    NSUInteger oldCount = (side == 0) ? gAevonDockLastRight : gAevonDockLastLeft;
                    NSUInteger newCount = (side == 0) ? right : left;
                    if (newCount >= oldCount) { continue; }
                    CGFloat originX = (side == 0) ? (sw - gAevonDockW) : 0;
                    for (NSUInteger i = newCount; i < oldCount && i < 5; i++) {
                        CGRect r = CGRectMake(originX, gAevonDockTop + (CGFloat)i * gAevonDockStep,
                                              gAevonDockW, gAevonDockH);
                        AevonGuardDockGhostAdd(CGRectInset(r, -slop, -slop), now);
                    }
                }
            }
        }
        gAevonDockLastRight = right;
        gAevonDockLastLeft = left;
    } @catch (NSException *exception) {
    }
}

/// 点是否落在某一格停靠小窗上（外扩 3pt 容错，卡片的描边也能算进去）。
///
/// V0.0.56：命中后把那一格记成「幽灵格」保留 1 秒 —— 轻点还原后小窗立刻离开槽位、
/// 下方整列上移补位，用户第二根手指几十毫秒后落回原位置时那里已经是 App 画面了。
static BOOL AevonGuardDockHitTest(CGPoint pt) {
    @try {
        CFTimeInterval now = CACurrentMediaTime();
        /* V0.0.70：逐格查幽灵表（2s 窗口），命中即吞 */
        for (NSInteger gi = 0; gi < gAevonDockGhostCount; gi++) {
            if (now < gAevonDockGhostUntil[gi]
                && !CGRectIsEmpty(gAevonDockGhosts[gi])
                && CGRectContainsPoint(gAevonDockGhosts[gi], pt)) {
                return YES;
            }
        }
        NSUInteger right = 0, left = 0;
        if (AevonGuardDockCounts(&right, &left) == 0) { return NO; }
        if (gAevonDockW < 1.0) { AevonGuardDockMetrics(); }
        if (gAevonDockW < 1.0) { return NO; }
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        /* V0.0.73：命中外扩 —— 横向 4pt（贴边留白），纵向 24pt（槽位顶边留白 + 取整误差） */
        const CGFloat slopX = 4.0;
        const CGFloat slopY = 24.0;
        for (NSUInteger side = 0; side < 2; side++) {
            NSUInteger count = (side == 0) ? right : left;
            CGFloat originX = (side == 0) ? (sw - gAevonDockW) : 0;
            for (NSUInteger i = 0; i < count; i++) {
                CGRect r = CGRectMake(originX, gAevonDockTop + (CGFloat)i * gAevonDockStep,
                                      gAevonDockW, gAevonDockH);
                if (CGRectContainsPoint(CGRectInset(r, -slopX, -slopY), pt)) {
                    /* V0.0.70：记录到幽灵表（去重续期，表满则覆盖最旧一条） */
                    CGRect rec = CGRectInset(r, -slopX, -slopY);
                    NSInteger slot = -1;
                    for (NSInteger gi = 0; gi < gAevonDockGhostCount; gi++) {
                        if (CGRectEqualToRect(gAevonDockGhosts[gi], rec)) { slot = gi; break; }
                    }
                    if (slot < 0) {
                        if (gAevonDockGhostCount < 8) {
                            slot = gAevonDockGhostCount++;
                        } else {
                            slot = 0;
                            for (NSInteger gi = 1; gi < 8; gi++) {
                                if (gAevonDockGhostUntil[gi] < gAevonDockGhostUntil[slot]) { slot = gi; }
                            }
                        }
                        gAevonDockGhosts[slot] = rec;
                    }
                    gAevonDockGhostUntil[slot] = now + 2.0;
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
static BOOL gAevonWinResizeWarned = NO;

/* V0.0.80（AevonNoWinResizeV80）：**这条通道整个关掉，只留诊断**。
 *
 * Aevon(72) 报了三件事，指向的是同一处：
 *   · 关闭所有浮窗后全屏触摸失灵，回桌面重开 App 才恢复；
 *   · 任何 App 的任何页面里，内容会自己整体往上滑并钉住，手动滑不下来，
 *     只能清后台重开；
 *   · 桌面部分小组件变空白。
 *
 * 旧实现每 1 秒（`sendEvent` 里调用，节流 1s）做一次：
 *   keyWindow（取不到就 `windows.firstObject`）frame ← `UIScreen.main.bounds`
 *   + `setNeedsLayout` + `layoutIfNeeded`
 * 三个问题：
 *   ① `windows.firstObject` 往往不是主窗口（可能是 alert / HUD / 键盘宿主窗口，
 *      甚至有 0 尺寸的垫片窗口）—— 把这种窗口撑成整屏，它会盖在主窗口上面，
 *      **整屏触摸全被它吃掉** = 「关掉浮窗后点不动」；
 *   ② 只要 frame 与屏幕差 0.5pt（浮点误差 / 系统过渡中间态），就会每秒无条件
 *      `frame = 屏幕` 并强制布局一次 —— App 的 UIScrollView 每秒钟被重排一次，
 *      contentOffset 反复被拽到同一个位置，就是「内容自己往上滑并钉住」；
 *   ③ V57 起我们**根本不再改小任何窗口**（显示改走浮窗侧等比缩放），
 *      这条「还原」兜底已经没有正当触发场景，剩下的只有风险。
 *
 * 现在：只在**真的检测到主窗口被改小**时写一条日志，绝不写 frame、绝不触发布局。
 * 保留旧日志串（AevonNoWinResizeV57）作为历史校验锚点 —— CI 用历史版本串做回归，
 * 串只能加不能改。 */
static void AevonGuardKeepWindowFull(void) {
    @try {
        static CFTimeInterval lastAt = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastAt < 10.0) { return; }
        lastAt = now;
        if (gAevonWinResizeWarned) { return; }   /* 只报一次，不给日志刷屏 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { return; }
        UIWindow *key = app.keyWindow;
        if (key == nil) { return; }               /* 没有 keyWindow 就什么都不做 */
        CGRect screen = [UIScreen mainScreen].bounds;
        if (screen.size.width < 1 || screen.size.height < 1) { return; }
        if (CGRectEqualToRect(key.frame, screen)) { return; }
        /* 只关心「明显被改小」的主窗口（< 屏高 90%）。轻微差异 = 正常过渡态，不管。 */
        if (key.frame.size.height >= screen.size.height * 0.9) { return; }
        if (key.windowLevel != UIWindowLevelNormal) { return; }
        gAevonWinResizeWarned = YES;
        AevonGuardWriteLog(NO, @"检测到主窗口被改小（%.0fx%.0f，屏幕 %.0fx%.0f）——"
                           @"本版**不再强行还原**（强行还原会吃掉整屏触摸 / 每秒强制布局"
                           @"导致内容自己上滑），如遇黑屏请重开该 App"
                           @"（AevonNoWinResizeV80 AevonNoWinResizeV57）",
                           key.frame.size.width, key.frame.size.height,
                           screen.size.width, screen.size.height);
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
        if (gAevonGuardPrefsNoZone) { AevonGuardZone = CGRectZero; }   /* V0.0.68 */
        return;
    }

    /* 2. guard.conf 文件通道 */
    if (AevonGuardReadConfFile(&zone, &enabled)) {
        AevonGuardEnabled = enabled;
        AevonGuardZone = enabled ? zone : CGRectZero;
        if (gAevonGuardPrefsNoZone) { AevonGuardZone = CGRectZero; }   /* V0.0.68 */
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
            if (gAevonGuardPrefsNoZone) { AevonGuardZone = CGRectZero; }   /* V0.0.68 */
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
            if (gAevonGuardPrefsNoZone) { AevonGuardZone = CGRectZero; }   /* V0.0.68 */
            return;
        }
    }

    AevonGuardEnabled = NO;
    AevonGuardZone = CGRectZero;
    /* V0.0.68（AevonGuardPrefsAliveV68）：设置页热区恒空（滑杆保护），浮窗判据照常。 */
    if (gAevonGuardPrefsNoZone) { AevonGuardZone = CGRectZero; }
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

/* V0.0.71（AevonGuardLateRejudgeV71）：began 竞态泄漏的短触摸回收。
 *
 * Aevon(64) 实锤：慢速轻点停靠小窗还原主窗 100% 穿透。根因不是宽限不够长，
 * 而是判定结构洞 —— Guard 只在 UITouchPhaseBegan 那一帧决定接管与否：
 * App 进程处理 began 几乎总比 SpringBoard 写 bit48 快几毫秒（SB 侧要先跑完
 * 浮窗命中测试才置位），Guard 读到 0 就放行；而 moved/ended 阶段只看 owned
 * 标记，哪怕此刻 bit48 已经是 1（0.7s 宽限全程有效）也绝不复查 —— 于是
 * began+ended 完整穿透进 App 合成一次点击。宽限（V67/V70）、幽灵格（V67/V70）
 * 都救不了「本条已泄漏的触摸序列」，它们只影响后续新触摸的判定输入。
 *
 * 修法：moved/ended/cancelled 阶段对未接管的触摸做一次**晚到重判** ——
 * 位移 <25pt（轻点特征；滚动/拖动必然远超）且此刻命中任一浮窗判据
 * （bit48 / 圆盘 / 主窗矩形 / 停靠格含幽灵格），立即接管吞掉。
 * App 只收到 began（外加零星 moved），没有 ended —— UIKit 不会合成点击，
 * 悬挂 touch 由系统自行取消。滚动 / 拖动手势位移必超阈值，完全不受影响。 */
/* V0.0.73（AevonGuardScreenPtV73）：触点必须换算到**屏幕坐标**再比几何。
 *
 * Aevon(66) 日志实锤坐标错位：同一次轻点，SpringBoard 记「窗身按下 374,161」，
 * App 进程 Guard 记「began 放行 x=386,y=72」—— 纵向差约 90pt。原因是
 * `locationInView:nil` 给的是**窗口坐标**，而停靠槽位 / 主窗矩形 / 热区全部是
 * **屏幕坐标**。停靠槽位顶边 = 屏高 10% = 93，Guard 读到的 y=72 差 21pt，
 * 四条判据全部落空 → began 放行 → 完整 began+ended 进 App = 一次点击。
 * 这也解释了为什么 V67 宽限、V70 幽灵格、V71 晚到重判（当时同样只比窗口坐标）
 * 全都「改了但没用」—— 它们喂给几何判据的坐标一直是错的。
 *
 * 修法：两套坐标都试 —— 窗口坐标（老行为，窗口正好在原点时才对）与
 * `[touch.window convertPoint:toWindow:nil]` 换算出的屏幕坐标，任一命中即命中。
 * 双保险：停靠槽位的命中外扩从 3pt 提到「横向 4pt / 纵向 24pt」，
 * 覆盖 dock 窗口顶部留白与像素取整误差。 */
static BOOL AevonGuardPointInRect(CGRect rect, CGPoint a, CGPoint b) {
    if (CGRectIsEmpty(rect)) { return NO; }
    return CGRectContainsPoint(rect, a) || CGRectContainsPoint(rect, b);
}

static CGPoint AevonGuardScreenPoint(UITouch *touch, CGPoint windowPoint) {
    @try {
        UIWindow *w = touch.window;
        if (w) {
            CGPoint c = [w convertPoint:windowPoint toWindow:nil];
            if (isfinite(c.x) && isfinite(c.y)) { return c; }
        }
    } @catch (NSException *e) { }
    return windowPoint;
}

/* V0.0.74（AevonGuardTapStampV74）：浮窗按下时间戳 —— **与坐标无关**的确定性判据。
 *
 * Aevon(66) 实锤：同一次轻点，SB 记 374,161，Guard 记 386,72，停靠槽位几何整条落空。
 * 坐标空间只要再变一次（多窗口 / 缩放 / 键盘宿主），几何判据就再次失配。
 * 所以再补一条只看时间的路：SB 每次浮窗按下写一个毫秒时间戳（同一系统时钟），
 * Guard 抬手时若发现「浮窗刚被按下 < 350ms」，直接吞掉 ended —— App 只剩 began，
 * UIKit 不会合成点击。跨进程时钟同源（CACurrentMediaTime = mach_absolute_time），
 * 允许 -50ms 的轻微超前，避免两进程调度抖动误判。 */
static CFTimeInterval AevonGuardFloatTapAge(void) {
    @try {
        static int token = -1;
        if (token < 0) {
            notify_register_check("com.aevon.guardtap", &token);
        }
        if (token < 0) { return -1.0; }
        uint64_t ms = 0;
        if (notify_get_state(token, &ms) != 0) { return -1.0; }
        if (ms == 0) { return -1.0; }
        CFTimeInterval nowMs = CACurrentMediaTime() * 1000.0;
        return (nowMs - (CFTimeInterval)ms) / 1000.0;
    } @catch (NSException *exception) {
        return -1.0;
    }
}

static BOOL AevonGuardRecentFloatTap(void) {
    CFTimeInterval age = AevonGuardFloatTapAge();
    if (age < 0) { return NO; }
    /* V0.0.78（AevonGuardTapWideV78）：窗口 350ms → 1500ms。
     *
     * Aevon(70) 复盘：350ms 只够「快速轻点」。用户报的是**慢速**轻点 —— 手指按在
     * 浮窗上停留几百毫秒再抬手，抬手那一刻 SB 的按下时间戳早就过期 350ms，
     * 而位移阈值 25pt 又被指尖漂移越过，两条判据同时落空 → 完整 began+ended
     * 进 App，合成一次点击。这正好解释「快速点没事、慢速点 100%」。
     * 1.5s 的代价：浮窗按下后 1.5s 内该 App 进程的触摸一并吞掉 —— 那段时间
     * 用户本来就在操作浮窗，App 不收触摸才是对的。 */
    return (age >= -0.05 && age <= 1.5);
}

static BOOL AevonGuardLateRejudgeHit(CGPoint winPt, CGPoint scrPt) {
    if (AevonGuardFloatTouch()) { return YES; }
    if (AevonGuardRingOpen()) { return YES; }
    CGRect floatRect = AevonGuardFloatRectRect();
    if (AevonGuardPointInRect(floatRect, winPt, scrPt)) { return YES; }
    if (AevonGuardDockHitTest(scrPt)) { return YES; }
    if (AevonGuardDockHitTest(winPt)) { return YES; }
    return NO;
}

/* V0.0.81（AevonAppGateV81）：整窗触摸门 —— 读 SB 写下的持续状态。
 *
 * Aevon(73) 日志实锤：停靠小窗被轻点时，App 侧收到的触摸坐标会乱跳
 * （同一次轻点 SB 记 384,174、Guard 记 218,295；下一次 375,186 → 184,476；
 *  再下一次 197,680 → 235,768），停靠格 / 主窗矩形 / 热区三条几何判据全部落空。
 * 既然坐标不可信，就改用**与坐标无关**的状态门：SB 在「停靠 / 关掉内容触摸 /
 * 该进程没有 Guard」时把这扇门关上，这里直接丢弃整条事件。
 *
 * 默认开门（notify state 初始 0），从没被显式关过的 App 行为完全不变。 */
static BOOL AevonGuardAppGateBlocked(void) {
    static int token = -1;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length > 0) {
            NSString *name = [@"com.aevon.gate." stringByAppendingString:bid];
            if (notify_register_check(name.UTF8String, &token) != 0) { token = -1; }
        }
    }
    if (token < 0) { return NO; }
    uint64_t v = 0;
    if (notify_get_state(token, &v) != 0) { return NO; }
    return (v != 0);
}

/* V0.0.81（AevonScrollLeakV81）：浮窗手势误把 App 滚动的还原。
 *
 * Aevon(73)：「全屏打开设置、悬浮窗里开电池数据，双击关掉浮窗后，设置页内容
 * 自己划到最底部，底部还出现大面积空白」。
 * 机制：手指压在浮窗上时 App 进程也会收到同一份触摸（backboardd 直投），
 * began 偶尔赶在 bit48 之前到（V71 说过的竞态）→ 那几帧 moved 被 App 的
 * UIScrollView 当真，内容被带着滚；而我们随后接管吞掉 ended，
 * App 的滚动会话就**停在那里**（无 ended = 一直“按着”），表现成「滚到底 + 空白 + 滑不回来」。
 *
 * 做法：began 放行时记下命中视图往上最近的 UIScrollView 的 contentOffset；
 * 一旦之后判定这条触摸属于浮窗（接管），把偏移还原回去，并尝试取消它的滚动会话。
 * 只在「有浮窗 + 我们接管」时动手，正常 App 内滚动完全不受影响。 */
static __weak UIScrollView *gAevonScrollWatch = nil;
static CGPoint gAevonScrollWatchOffset = {0, 0};
static BOOL gAevonScrollWatchArmed = NO;

static UIScrollView *AevonGuardScrollAncestor(UIView *view) {
    UIView *cur = view;
    while (cur != nil) {
        if ([cur isKindOfClass:[UIScrollView class]]) { return (UIScrollView *)cur; }
        cur = cur.superview;
    }
    return nil;
}

static void AevonGuardArmScrollWatch(UIWindow *window, CGPoint point, UIEvent *event) {
    @try {
        if (window == nil) { gAevonScrollWatchArmed = NO; return; }
        UIView *hit = [window hitTest:point withEvent:event];
        UIScrollView *sv = AevonGuardScrollAncestor(hit);
        gAevonScrollWatch = sv;
        gAevonScrollWatchOffset = (sv != nil) ? sv.contentOffset : CGPointZero;
        gAevonScrollWatchArmed = (sv != nil);
    } @catch (NSException *exception) {
        gAevonScrollWatchArmed = NO;
    }
}

static void AevonGuardRestoreScrollIfLeaked(const char *why) {
    if (!gAevonScrollWatchArmed) { return; }
    gAevonScrollWatchArmed = NO;
    UIScrollView *sv = gAevonScrollWatch;
    if (sv == nil) { return; }
    @try {
        CGPoint now = sv.contentOffset;
        CGFloat dy = fabs(now.y - gAevonScrollWatchOffset.y);
        CGFloat dx = fabs(now.x - gAevonScrollWatchOffset.x);
        if (dy < 1.0 && dx < 1.0) { return; }
        sv.contentOffset = gAevonScrollWatchOffset;
        SEL stopSel = NSSelectorFromString(@"_stopScrollingNotify:pinContent:");
        if ((sv.isDragging || sv.isTracking) && [sv respondsToSelector:stopSel]) {
            void (*fn)(id, SEL, BOOL, BOOL) = (void *)[sv methodForSelector:stopSel];
            if (fn) { fn(sv, stopSel, YES, NO); }
        }
        AevonGuardWriteLog(NO, @"浮窗手势泄漏把 App 滚动了 %.0fpt → 已还原（%s，app=%@）（AevonScrollLeakV81）",
                           dy, why, [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
    } @catch (NSException *exception) {
    }
}

static void AevonGuardSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (AevonGuardOrigSendEvent == NULL) {
        return;
    }
    /* V0.0.81（AevonAppGateV81）：整窗触摸门 —— 最前面，先于任何坐标判定。
     *
     * 停靠小窗 / 内容触摸被关掉 / 该 App 没有 Guard 的降级态，SB 会把门关上，
     * 这里整条事件丢弃：App 既收不到点击，也收不到滚动 —— 不依赖任何坐标，
     * 也就不存在「同一次轻点两边坐标差 90~200pt」这类判据落空的问题。 */
    if (AevonGuardAppGateBlocked()) {
        static CFTimeInterval lastGateLog = 0;
        CFTimeInterval gateNow = CACurrentMediaTime();
        if (gateNow - lastGateLog > 3.0) {
            lastGateLog = gateNow;
            AevonGuardWriteLog(NO, @"整窗触摸门关闭 → 丢弃本条事件（浮窗这段时间不该把触摸给 App；"
                               @"与坐标无关，app=%@）（AevonAppGateV81）",
                               [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
        }
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
    /* V0.0.72：每条事件先做一次停靠数量变化检测（幽灵格自动记录，轻量状态比较） */
    AevonGuardDockGhostAutoRecord();
    for (UITouch *touch in touches) {
        UITouchPhase phase = [touch phase];
        if (phase == UITouchPhaseStationary) { continue; }
        active += 1;

        BOOL owned = AevonGuardTouchOwned(touch);

        if (phase == UITouchPhaseBegan) {
            CGPoint pt = [touch locationInView:nil];
            /* V0.0.73：同一触点的两套坐标 —— 窗口坐标（老行为）+ 屏幕坐标（几何判据的真坐标系） */
            CGPoint spt = AevonGuardScreenPoint(touch, pt);
            /* V0.0.71：无条件记录起点 —— 晚到重判要按「总位移」区分轻点与滚动，
             * 不能只在热区命中时才记（旧实现只有热区路径写 start）。 */
            AevonGuardSetTouchStart(touch, spt);
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
            BOOL dockHit = (AevonGuardDockHitTest(spt) || AevonGuardDockHitTest(pt));
            if (floatTouch) {
                /* V0.0.49：浮窗手势期 —— 整屏吞。手指压在浮窗上时，
                 * App 不该收到任何输入（这是「点小窗还原 → 抖音暂停」的正面修法）。 */
                hardZone = YES;
            } else if (ringOpen) {
                /* V0.0.35：圆盘开着 —— **整屏**吞掉（连顶部 18% 也吞，状态栏区无交互需求）。
                 * 旧版留 18% 是给「万一圆盘需要顶部交互」，实际不存在这个场景，
                 * 反而多留一条缝。图标选择 / 旋转走 SpringBoard 全局通道副本，不依赖这里投递。 */
                hardZone = YES;
            } else if (hasFloatRect && AevonGuardPointInRect(floatRect, pt, spt)) {
                /* V0.0.56：落在主悬浮窗（含外侧手势区）上 —— 这块屏幕本来就被浮窗盖着，
                 * App 不该收到任何输入。双击的第二下（间隔 0.36s > bit48 的 350ms 放行）
                 * 就靠这条判据兜住。V0.0.73 起两套坐标都试。 */
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
                /* V0.0.77（AevonGuardSwallowProbeV77）：**正向**取证。
                 * 旧日志只在「放行」时说话，于是「App 到底有没有收到这次轻点」
                 * 永远只能靠推理。这里把每一次吞掉的 began 也记下来（限频 1s），
                 * 下一轮日志就能三选一：①压根没这行 = 触摸没进这个进程
                 * （问题在转发端/别的 App 进程）；②有这行且没放行 = 吞了，
                 * 那就得去别的 App 进程找点击；③有放行 = 判据漏了。 */
                static CFTimeInterval lastSwallowProbe = 0;
                CFTimeInterval swNow = CACurrentMediaTime();
                if (swNow - lastSwallowProbe > 1.0) {
                    lastSwallowProbe = swNow;
                    AevonGuardWriteLog(NO, @"吞摸取证（began win=%.0f,%.0f scr=%.0f,%.0f float=%d ring=%d rect=%d dock=%d app=%@）",
                                       pt.x, pt.y, spt.x, spt.y,
                                       floatTouch ? 1 : 0,
                                       ringOpen ? 1 : 0,
                                       AevonGuardPointInRect(floatRect, pt, spt) ? 1 : 0,
                                       dockHit ? 1 : 0,
                                       [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
                }
            } else {
                /* V0.0.81（AevonScrollLeakV81）：这条 began 准备放行 —— 先记下它落点
                 * 所属滚动视图的偏移。万一之后我们判定它其实属于浮窗（接管），
                 * 就能把被带着滚走的偏移还原回去（见 AevonGuardRestoreScrollIfLeaked）。 */
                AevonGuardArmScrollWatch(touch.window, pt, event);
                /* V0.0.72（AevonGuardPassProbeV72）：began 放行取证 —— 右缘停靠带上的
                 * 放行是穿透的必然前兆，限频 1s 打一条，下一轮日志直接定位漏网判据。
                 * V0.0.73：同时打两套坐标 + 窗口 frame + Guard 自己算出的槽位几何，
                 * 坐标错位 / 度量偏差一眼可辨。 */
                CGFloat sw2 = [UIScreen mainScreen].bounds.size.width;
                if (gAevonDockW < 1.0) { AevonGuardDockMetrics(); }
                /* V0.0.78（AevonGuardLeakWitnessV78）：**只要存在任何浮窗态就记**。
                 * 旧实现只在「右缘停靠带 30pt 内」才打放行日志，而限频 1s 又会把
                 * 同一秒里的第二条淹没 —— 于是「App 到底有没有拿到 began」永远无法证明。
                 * 现在 float / ring / docked / 主窗矩形 任一成立就记，限频 0.5s。 */
                if (floatTouch || ringOpen || docked || hasFloatRect
                    || spt.x >= sw2 - gAevonDockW - 30.0 || pt.x >= sw2 - gAevonDockW - 30.0) {
                    static CFTimeInterval lastProbe = 0;
                    CFTimeInterval now2 = CACurrentMediaTime();
                    if (now2 - lastProbe > 0.5) {
                        lastProbe = now2;
                        NSUInteger r2 = 0, l2 = 0;
                        AevonGuardDockCounts(&r2, &l2);
                        CGRect wf = CGRectZero;
                        @try { if (touch.window) { wf = touch.window.frame; } } @catch (NSException *e) { }
                        AevonGuardWriteLog(NO, @"began 放行（win=%.0f,%.0f scr=%.0f,%.0f float=%d ring=%d rect=%d dockR=%lu ghost=%lu winFrame=%.0f,%.0f,%.0f,%.0f slot=%.0f,%.0f %.0fx%.0f）",
                                           pt.x, pt.y, spt.x, spt.y,
                                           floatTouch ? 1 : 0,
                                           ringOpen ? 1 : 0,
                                           AevonGuardPointInRect(floatRect, pt, spt) ? 1 : 0,
                                           (unsigned long)r2,
                                           (unsigned long)gAevonDockGhostCount,
                                           wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
                                           sw2 - gAevonDockW, gAevonDockTop, gAevonDockW, gAevonDockH);
                    }
                }
            }
            if (!owned && !CGRectIsEmpty(AevonGuardZone)
                && AevonGuardPointInRect(AevonGuardZone, pt, spt)) {
                /* V0.0.56：**热区改为「移动才吞」**。
                 *
                 * 热区（屏幕右边缘 18pt 宽、底边往上 258pt）是呼出圆盘用的，
                 * 触发条件是「左滑 ≥ 30pt」——纯点击根本不该被吞。
                 * 但旧实现 began 就无条件吞，于是这条 18pt 竖条上的 App 按钮
                 * （抖音右侧工具栏最后几个正好压在 x≈412~430）永远点不动，
                 * 用户 Aevon(50) 第 3 条「屏幕部分位置无法点击」的另一半就是它。
                 * 现在只记起点、先放行；真正出现横向拖动（> 8pt）才接管，
                 * 手势照样呼得出圆盘，纯点击则完整交给 App。
                 * （V0.0.71 起 began 已无条件记起点，这里重复设置同值，仅保留判读注释。） */
                AevonGuardSetTouchStart(touch, spt);
            }
        } else if (phase == UITouchPhaseMoved && !owned) {
            CGPoint start;
            if (AevonGuardGetTouchStart(touch, &start)) {
                CGPoint now = [touch locationInView:nil];
                CGPoint snow = AevonGuardScreenPoint(touch, now);
                CGFloat dx = snow.x - start.x;
                CGFloat dy = snow.y - start.y;
                /* 只有「往左划」才接管 —— 那才是呼出圆盘的手势（SB 侧判据：左滑 ≥30pt）。
                 * 纯点击、竖向滚动（抖音右侧上下滑）、向右划一律放行，
                 * App 拿到的是完整触摸序列，不会出现「按钮点不动」或「滑到一半断掉」。 */
                if (dx < -8.0 && fabs(dx) >= fabs(dy)) {
                    AevonGuardSetTouchOwned(touch, YES);
                    owned = YES;
                } else if (AevonGuardRecentFloatTap()
                           || (hypot(dx, dy) < 25.0 && AevonGuardLateRejudgeHit(now, snow))) {
                    /* V0.0.71（AevonGuardLateRejudgeV71）：began 竞态泄漏的回收 ——
                     * 位移还很小（仍是轻点）且此刻任一浮窗判据已成立，立刻接管。 */
                    AevonGuardSetTouchOwned(touch, YES);
                    owned = YES;
                    AevonGuardRestoreScrollIfLeaked("moved");
                    /* V0.0.72：取证（限频 1s）——确认晚到重判真的在工作 */
                    static CFTimeInterval lastRejudgeMoved = 0;
                    CFTimeInterval now3 = CACurrentMediaTime();
                    if (now3 - lastRejudgeMoved > 1.0) {
                        lastRejudgeMoved = now3;
                        AevonGuardWriteLog(NO, @"晚到重判接管（moved，位移 %.0fpt，win=%.0f,%.0f scr=%.0f,%.0f）",
                                           hypot(dx, dy), now.x, now.y, snow.x, snow.y);
                    }
                }
            }
        }

        /* V0.0.71（AevonGuardLateRejudgeV71）：ended / cancelled 的最后一道闸。
         * began 泄漏的序列若一路没动（<25pt），抬手时此刻 bit48/停靠格/主窗矩形
         * 已全部就位 —— 命中即吞掉 ended：App 只剩一个无 ended 的 began，
         * UIKit 不会合成点击（这正是「点小窗还原 → App 被点一下」的终结）。 */
        if (!owned && (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled)) {
            CGPoint now = [touch locationInView:nil];
            CGPoint snow = AevonGuardScreenPoint(touch, now);
            CGPoint start = CGPointZero;
            CGFloat dist = 0;
            if (AevonGuardGetTouchStart(touch, &start)) {
                dist = hypot(snow.x - start.x, snow.y - start.y);
            }
            BOOL stampHit = AevonGuardRecentFloatTap();
            /* V0.0.78（AevonGuardTapWideV78）：stampHit 命中就**不再看位移**。
             * 时间戳通道本身就意味着「浮窗刚被按下」，App 这一份触摸绝不该生效；
             * 再叠一条「位移 <25pt」等于给自己留了个慢速轻点的漏口（见上）。 */
            if (stampHit || (dist < 25.0 && AevonGuardLateRejudgeHit(now, snow))) {
                AevonGuardSetTouchOwned(touch, YES);
                owned = YES;
                AevonGuardRestoreScrollIfLeaked("ended");
                /* V0.0.72：取证（限频 1s）——ended 闸生效证据
                 * V0.0.74：stamp=1 表示「浮窗刚被按下」时间戳命中（不依赖坐标） */
                static CFTimeInterval lastRejudgeEnded = 0;
                CFTimeInterval now4 = CACurrentMediaTime();
                if (now4 - lastRejudgeEnded > 0.5) {
                    lastRejudgeEnded = now4;
                    AevonGuardWriteLog(NO, @"晚到重判接管（ended，位移 %.0fpt，win=%.0f,%.0f scr=%.0f,%.0f，stamp=%d）",
                                       dist, now.x, now.y, snow.x, snow.y,
                                       stampHit ? 1 : 0);
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

    /* V0.0.77（AevonGuardPartialSwallowV77）：**只要有一条被接管，整条事件丢弃**。
     * 旧实现是 `swallowed == active` 才丢，否则整条交给 App —— 等于把刚刚判定为
     * 「压在浮窗上，App 不该收到」的那根手指**又原样投递**给了 App。多指 / 前后脚
     * 触摸时这就是一条完整的泄漏通道（判据全对、日志也显示接管了，App 照样被点中）。
     * 代价：浮窗手势期里另一根手指的滚动会被一起丢掉 —— 这本来就是想要的行为。 */
    if (swallowed > 0 && swallowed != active) {
        static CFTimeInterval lastPartial = 0;
        CFTimeInterval pnow = CACurrentMediaTime();
        if (pnow - lastPartial > 1.0) {
            lastPartial = pnow;
            AevonGuardWriteLog(NO, @"部分吞 → 整条丢弃（接管 %lu / 活跃 %lu，含多指）",
                               (unsigned long)swallowed, (unsigned long)active);
        }
        swallowed = active;
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


/* V0.0.77（AevonGuardAliveV77）：Guard 存活登记。
 *
 * Aevon(69) 日志实锤：只有「tweak 加载之后新启动的 App」才有注入日志
 * （Spotlight / BatteryInfo / Sileo / Preferences / Filza 有，浮窗里的 GitHub 一条都没有）。
 * 老进程里没有 Guard，浮窗内容一旦把触摸转发进去，App 自己就合成了一次点击 ——
 * 这才是「轻点停靠小窗还原主窗 → App 内被点一下」活过多版本的真身。
 *
 * 这里把本进程的 pid 写进 `com.aevon.alive.<bundleID>`，SpringBoard 侧创建浮窗时
 * 读一下就知道该 App 进程里到底有没有 Guard；没有就当场降级（关掉内容触摸）+ 写日志点名。 */
static void AevonGuardPublishAlive(void) {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) { bid = [NSString stringWithUTF8String:getprogname() ?: "?"]; }
        NSString *name = [@"com.aevon.alive." stringByAppendingString:bid];
        int token = -1;
        if (notify_register_check(name.UTF8String, &token) == 0 && token >= 0) {
            notify_set_state(token, (uint64_t)(getpid() & 0x7FFFFFFF));
            notify_post(name.UTF8String);
            notify_cancel(token);
        }
    } @catch (NSException *e) { }
}

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

    /* V0.0.68（AevonGuardPrefsAliveV68）：注入自检 —— 每个 GUI App 进程装好后
     * 写一条到 /var/mobile/Aevon.log。下一轮日志能直接看出 Guard 活在哪些 App 里
     * （Aevon(61) 靠圆盘 ack 警告倒推出 Preferences 被排除，太绕）。 */
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        AevonGuardWriteLog(YES, @"Guard 已注入：%@（热区=%@，进程=%s）",
                           bid,
                           gAevonGuardPrefsNoZone ? @"禁用（设置页滑杆保护）" : @"启用",
                           getprogname());
    } @catch (NSException *e) { }
    /* V0.0.34（AevonGuardLogV34）：注入确认日志 —— 用户日志里出现这行就说明 Guard 真的进了这个 App */
    AevonGuardWriteLog(YES, @"已注入进程 %@（bundle %@），sendEvent 拦截就绪（AevonGuardStateRingV34 AevonGuardLogV34 AevonGuardRingExactV37）",
                       [NSString stringWithUTF8String:getprogname() ?: "?"],
                       [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
    /* V0.0.72（AevonGuardGhostAutoV72）：版本取证 —— 驻留 App 进程 respring 后不会重启，
     * 里面跑的可能还是旧版 Guard；下一轮日志靠版本号直接区分新旧进程。 */
    AevonGuardWriteLog(YES, @"Guard 版本 V72 激活（晚到重判 + 幽灵自动记录）（AevonGuardGhostAutoV72）");
    /* V0.0.73（AevonGuardScreenPtV73）：坐标换算到屏幕坐标再比几何 —— Aevon(66) 实锤
     * 窗口坐标与屏幕坐标纵向差约 90pt，停靠槽位判据整条落空。 */
    AevonGuardWriteLog(YES, @"Guard 版本 V73 激活（窗口/屏幕双坐标系判据 + 停靠格纵向外扩 24pt）（AevonGuardScreenPtV73）");
    /* V0.0.74（AevonGuardTapStampV74）：与坐标无关的时间戳兜底 —— 抬手时浮窗刚被按下就吞 ended。 */
    AevonGuardWriteLog(YES, @"Guard 版本 V74 激活（浮窗按下时间戳兜底 + 双坐标系几何）（AevonGuardTapStampV74）");
    /* V0.0.77（AevonGuardAliveV77）：存活登记 —— 让 SpringBoard 侧能查出「这个 App 进程里有没有 Guard」。 */
    AevonGuardPublishAlive();
    AevonGuardWriteLog(YES, @"Guard 版本 V77 激活（存活登记 com.aevon.alive.<bundle>，pid=%d）（AevonGuardAliveV77）", (int)getpid());
    /* V0.0.78（AevonAliveFileV78）：notify state 读不回来（Aevon(70)：6 个进程全被判成「无 Guard」），
     * 补一条文件登记 —— Aevon.log 已证明 App 进程能写 /var/mobile，这条路可靠。 */
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier]
            ?: [NSString stringWithUTF8String:getprogname() ?: "?"];
        /* Guard 是独立 dylib（只编本文件），不能调垫片里的实现 —— 直接写文件。 */
        NSString *alivePath = [@"/var/mobile/Aevon.alive." stringByAppendingString:bid];
        [[NSString stringWithFormat:@"%d", (int)getpid()] writeToFile:alivePath
                                                          atomically:YES
                                                            encoding:NSUTF8StringEncoding
                                                               error:NULL];
        AevonGuardWriteLog(YES, @"Guard 版本 V78 激活（文件存活登记 Aevon.alive.<bundle> + 时间戳窗口 1.5s + 放行取证不节流）（AevonAliveFileV78 AevonGuardTapWideV78 AevonGuardLeakWitnessV78）");
    } @catch (NSException *e) { }
}

/*
 * V0.0.69（AevonGuardLateStartV69）：**constructor 时机不再要求 sharedApplication 已存在**。
 *
 * 铁证（52 份历史日志回执警告统计）：V0.0.59~V0.0.62 的日志全部 0 条
 * 「未收到 App 侧回执」，V0.0.63 起每次圆盘呼出必告警 —— Guard 从 V63 起在
 * 所有 App 进程全灭。根因是 V0.0.62 在 constructor 里加的
 * `[UIApplication sharedApplication] == nil → return`：
 * dylib constructor 的运行时机远早于 main()/UIApplicationMain 创建
 * UIApplication 实例，这个检查恒为 nil → Guard 从不安装。
 * 连锁后果：停靠还原穿透（幽灵格/bit48/主窗矩形判据全失效）、
 * 圆盘滑动穿透成 App 左滑（bit39 吞摸失效）、所有 Guard 侧修复形同虚设。
 *
 * 现在的安装时机策略：
 *  · constructor 里 sharedApplication 已存在（个别进程晚注入）→ 立即装；
 *  · 否则延到主队列重试（100ms × 最多 100 次 = 10 秒），
 *    等 UIApplication 真正创建后再装 —— hook sendEvent 是类级操作，
 *    任何时候装都来得及（App 的触摸必然发生在启动完成之后）。
 *  · headless 进程（无主 runloop 或永不创建 sharedApplication）10 秒后自然放弃，
 *    等效于旧的「实例不存在 = headless」保险；扩展进程仍由 constructor 里的
 *    NSExtension/.appex 检查先行拦截，两道保险都保留。
 */
static void AevonGuardDeferredInstall(int attempt) {
    if ([UIApplication sharedApplication] != nil) {
        @try {
            AevonGuardInstall();
        } @catch (NSException *exception) {
            // 任何异常都不允许影响 App 启动
        }
        return;
    }
    if (attempt >= 100) { return; }   // 10 秒仍无 sharedApplication = headless，放弃
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonGuardDeferredInstall(attempt + 1);
    });
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
         * V0.0.68（AevonGuardPrefsAliveV68）：**「设置」App 不再整体排除**。
         *
         * V0.0.28 排除 com.apple.Preferences 是因为当时热区「began 无条件吞」会吃掉
         * 设置页滑杆的向左拖动。代价是一个多版本反复的大洞：用户拿「设置」App 测浮窗时
         * （Preferences 正是前台 App），停靠小窗 / 主窗矩形 / bit48 所有判据全部失效 ——
         * 轻点停靠小窗还原主窗必然穿透合成一次 App 内点击（Aevon(60)/(61) 日志 +
         * 圆盘三次呼出全部无回执实锤）。现在改为：照常装 Guard，
         * 只把 gAevonGuardPrefsNoZone 置位（热区恒空，滑杆保护），
         * 浮窗判据全部恢复 —— 这些判据都以浮窗状态激活为前提，不碰滑杆。
         */
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
            gAevonGuardPrefsNoZone = YES;
        }

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
        /* V0.0.80（AevonGuardNoWidgetV80）：小组件宿主（Chrono / WidgetKit）再排一道。
         * Aevon(72) 第 3 条「桌面部分小组件消失、默认空白」—— .appex 已经拦掉扩展本体，
         * 但小组件的渲染宿主还有几个非 .appex 的进程。它们完全不需要浮窗触摸门控，
         * 装上 sendEvent 拦截只会增加崩掉 / 空白的概率。 */
        if ([bundleID hasPrefix:@"com.apple."] &&
            ([bundleID containsString:@"widget"] || [bundleID containsString:@"chrono"])) {
            return;
        }

        /* V0.0.69：constructor 时 sharedApplication 几乎必然未创建 → 走延迟安装 */
        AevonGuardDeferredInstall(0);
    }
}
