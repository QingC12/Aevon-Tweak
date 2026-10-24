#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 偏好写入（在 Objective-C 中调用 CFPreferences，规避 Swift 对 CFPropertyListRef 的类型推断歧义）。
/// 读写域与设置界面（Preferences.framework）一致：com.Aevon。
void AevonPrefSetBool(NSString *key, BOOL value);
void AevonPrefSetInt(NSString *key, NSInteger value);
void AevonPrefSetDouble(NSString *key, double value);

@interface AevonAssertionShim : NSObject
+ (void)acquireKeepAliveForPID:(int)pid;
+ (void)releaseKeepAliveForPID:(int)pid;
/// 仅恢复进程执行（不取断言）：suspended 拉起的 App 必须恢复才会渲染画面。
+ (void)resumePID:(int)pid;
@end

/// 取 App 图标（SpringBoard 私有：SBIconController -applicationIconImageForBundleIdentifier:format:scale:）。
/// 全程 @try/@catch，取不到返回 nil —— 调用方必须准备文字兜底，绝不因图标缺失而失败。
UIImage *AevonIconImage(NSString *bundleID, CGFloat scale);

/// V0.0.32：跨进程热区配置通道（notify_set_state / notify_get_state）。
/// 沙盒 App 读不到 com.Aevon 偏好域、也未必能读 jbroot 文件，但 notify(3) 状态
/// 在沙盒里通用 —— SpringBoard 写入后，注入 App 的 AevonGuard 直接读。
/// 打包：x(10bit) y(10bit) w(8bit) h(10bit) enabled(1bit) ring(1bit) + 版本标记(8bit)。
void AevonNotifySetZone(double x, double y, double w, double h, int enabled);
/// 读到有效配置返回 1，否则 0（不改动出参）。
int AevonNotifyGetZone(double *x, double *y, double *w, double *h, int *enabled);
/// V0.0.34：圆盘展开状态位（notify state bit39，AevonNotifyRingBitV34）。
/// SpringBoard 在圆盘开 / 关时调用；Guard 每条 sendEvent 直接读共享内存，
/// 不再依赖 Darwin 广播送达（沙盒 App 里 fire-and-forget 通知不可靠）。
void AevonNotifySetRing(int on);

/// V0.0.49（AevonFloatTouchBitV49）：浮窗触摸期状态位（notify state bit48）。
///
/// Aevon(42) 第 1 条：「点停靠小窗还原时，App 里也吃到了一次点击（抖音暂停）」。
/// 根因是 **双投递** —— 前台 App 的触摸由 backboardd 直投 App 进程，
/// SpringBoard 只是同时收到一份；SB 里吞掉只是我们这份，App 那份照旧触发 tap。
/// 所以 SpringBoard 在浮窗手势按下 / 结束时写这个位，注入 App 的 AevonGuard
/// 读到就整屏吞掉那几帧事件（手指正压在浮窗上，App 本就不该收到输入）。
void AevonNotifySetFloatTouch(int on);

/// V0.0.74（AevonGuardTapStampV74）：浮窗按下的毫秒时间戳（通道 com.aevon.guardtap）。
///
/// 坐标类判据在 App 进程里不可靠（窗口坐标 ≠ 屏幕坐标，Aevon(66) 实锤差 ~90pt），
/// 这里改走**时间**：SB 每次浮窗按下写时间戳，Guard 在 ended 时若发现
/// 「抬手时浮窗刚被按下 < 350ms」就直接吞掉 ended，与坐标完全无关。
void AevonNotifyStampFloatTouch(void);

/// V0.0.54（AevonGuardDockZoneV54）：停靠列数量状态位（notify state bit50~55）。
///
/// Aevon(47) 第 5 条：「快速点击停靠的小窗轮换时，依旧会触发应用内的点击」。
/// bit48 是「按下写、抬手清」的实时位，与 backboardd 直投 App 的那一份存在时序竞态。
/// 停靠列几何是固定的（顶部 10% 起点、每格 dockH+8、左右贴边），所以这里只传
/// 「每侧有几个停靠小窗」，让 Guard 自己算出槽位矩形并吞摸 —— 零时序依赖。
/// rightCount / leftCount 传 -1 表示该侧保持原值。
void AevonNotifySetDockState(int rightCount, int leftCount);

/// V0.0.56（AevonGuardFloatRectV56）：主悬浮窗矩形通道（独立 notify token `com.aevon.guardfloat`）。
///
/// Aevon(50) 第 2 / 5 条：双击底边关闭、快速连点停靠小窗时，App 仍会吃到一次点击。
/// 主窗本体没有几何判据，光靠 bit48（有竞态）堵不住。这里把「主窗 + 外侧手势区」
/// 的矩形写进共享内存，Guard 命中就吞 —— 与触摸时序无关。
/// 传 w/h < 1 表示当前没有主悬浮窗（Guard 不再按矩形吞）。
void AevonNotifySetFloatRect(double x, double y, double w, double h);

/// V0.0.56（AevonAdaptiveWindowV56）：App 窗口目标尺寸（独立 token `com.aevon.guardwinsize`）。
///
/// Aevon(50) 第 4 条：只改场景 frame 只裁了渲染视口，App 的 UIWindow 仍是整屏 →
/// 内容按整屏排版、右边框被切掉。Guard（注入 App 进程）读到尺寸后直接改 keyWindow.frame，
/// App 才会真正按窗口尺寸重排。w/h < 40 表示恢复整屏。
void AevonNotifySetWindowSize(double w, double h);

/// V0.0.81（AevonAppGateV81）：**整窗触摸门**（每个 App 一个独立 token `com.aevon.gate.<bundle>`）。
///
/// Aevon(73) 复盘：停靠小窗被轻点时，App 进程仍会收到那一份**物理触摸**
/// （backboardd 直投前台 App，不是我们转发进去的）。旧办法是在 Guard 里按
/// 「停靠格几何 / 主窗矩形 / 按键时间戳」逐条判定要不要吞 —— 全部依赖 App 进程
/// 里的触摸坐标，而那份坐标一直是错的（日志里同一次轻点 SB 记 384,174、
/// Guard 记 218,295，甚至 180,103 / 235,768 乱跳），几何判据必然漏。
///
/// 这里改成**与坐标完全无关**的「状态门」：只要该浮窗当前不该接收内容触摸
/// （停靠小窗 / 设置里关掉内容触摸 / 该进程没有 Guard），SB 就把这扇门关上，
/// Guard 在 `sendEvent:` 最前面直接丢弃整个事件 —— 不需要知道手指在哪。
/// 门是**持续状态**（不是每条触摸现判），所以不存在「began 竞态漏一条」的问题。
///
/// blocked = 1 关门（App 收不到任何触摸），0 开门。默认（从未写过）= 0 = 开门，
/// 保证任何异常情况下 App 都不会被莫名其妙锁死。
void AevonNotifySetAppGate(NSString *bundleID, int blocked);

/// V0.0.82（AevonScrollHealV82）：**主悬浮窗整窗矩形**（独立 token `com.aevon.floatwin`）。
///
/// 和 `AevonNotifySetFloatRect`（只带底边手势环带、用来**吞摸**）是两个用途，
/// 千万别合并：这个矩形带的是**整窗**（含内容区），Guard 只用它做两件事：
///   ① 手指按在浮窗上时，记下 App 最上层 UIScrollView 的 contentOffset；
///   ② 抬手时若偏移被带着跑了 > 20pt，还原回去。
///
/// 为什么要它：Aevon(74)「全屏开设置 + 浮窗开电池数据，关掉浮窗后设置滑到最底、
/// 底部一片空白，100% 复现」。那条触摸**同时**投给了 SpringBoard 和前台 App
/// （backboardd 直投），App 那份落在它自己的全屏窗口上，于是被它自己的
/// UIScrollView 当真滚了 —— 这一路上我们没有任何代码在拦（V81 的误滚还原只在
/// 「我们接管了这条触摸」时才还原，而内容区的触摸我们是放行的，所以日志里
/// `已还原` 一条都没有）。这里补上「放行也要还原」这一半。
///
/// 传 w/h < 1 表示当前没有主悬浮窗（Guard 不做误滚还原）。
void AevonNotifySetFloatWindowRect(double x, double y, double w, double h);

/// V0.0.82（AevonScrollHealV82）：标记「这个 App 就是当前主悬浮窗里显示的那个 App」
/// （每 App 一个独立 token `com.aevon.floatowner.<bundle>`，1=是 0=不是）。
///
/// 为什么误滚还原必须把主人排除掉：浮窗里的内容本来就是**这个 App 自己的画面**，
/// 用户在上面滑动 = 正当滚动，还原它等于把用户的操作撤销掉。
/// 需要还原的只是「背后那个全屏 App」—— 它收到的是同一根手指的另一份投递。
void AevonNotifySetFloatOwner(NSString *bundleID, int isOwner);

/// V0.0.83（AevonFloatOwnerV83）：浮窗主人的**全局指纹**通道（`com.aevon.floatowner.bundle`）。
///
/// per-bundle token 那一版实测认错过主人（BatteryInfo 的正当滚动被还原），所以再补
/// 一条只存一个值的通道：高 32 位 = bundleID 的 djb2 指纹，bit0 = 有效位；空串 = 清。
/// Guard 侧只做整数比较（`AevonBundleFingerprint` 同名函数在 Guard 里也有一份，必须一致）。
void AevonNotifySetFloatOwnerBundle(NSString *bundleID);

/// bundleID 的 32 位 djb2 指纹（两侧必须用同一实现；空串返回 0 = 无效）。
uint32_t AevonBundleFingerprint(NSString *bundleID);

/// V0.0.39（AevonBootShieldV39）：ObjC 异常保护块。
/// 同步执行 block；抛出 NSException 时捕获并把名称 / 原因带回（任一出参可为 NULL），
/// 返回 YES = 正常完成，NO = 抛了异常。入口窗口创建等启动关键路径用它兜底，
/// 保证 UIKit 抛异常时 SpringBoard 不再被带崩（V0.0.38 自动注销问题）。
BOOL AevonTryExecute(void (^block)(void), NSString **outName, NSString **outReason);

/// V0.0.39（AevonCrashTraceV39）：execinfo 转发。
/// Swift 的 Darwin 模块在部分 SDK 上不暴露 backtrace / backtrace_symbols_fd，
/// 经 ObjC 垫片转发（崩溃信号处理里用，抓当前线程调用栈写入崩溃文件）。
NSInteger AevonBacktrace(void **stack, int max);
void AevonBacktraceSymbolsFD(void **stack, int size, int fd);

/// V0.0.40（AevonCrashAttrV40）：崩溃归因。
/// 插件加载时调用一次：算出自身 __TEXT 段地址范围（dladdr + mach-o 解析）。
/// 真机 Aevon(32) 定论：ZZEvoCenterRuntime.dylib 崩溃也会被我们的信号处理器
/// 捕获记录，崩溃保护误把 Aevon 自动禁用 → 用户永远开不起来插件。
void AevonCrashAttrPrepare(void);
/// 判定回溯栈（跳过前 skip 帧：AevonBacktrace / 信号处理器 / sigtramp 跳板）
/// 里有没有落在 Aevon 自身地址段内的帧。返回 1 = Aevon 参与（要负责），
/// 0 = 外部模块引起（不背锅、不禁用）。纯指针比较，信号处理内安全。
int AevonCrashAttrOwnsFrame(void **stack, int count, int skip);

/// V0.0.84（AevonEntityIntV84）：按**真实返回类型**读 `SBApplication` 上的整型/布尔属性。
///
/// 为什么必须走垫片：Swift 那边用 `@convention(c) (AnyObject, Selector) -> Int`
/// 把返回 `unsigned int` 的方法当成返回 64 位整型来读，x0 高 32 位是**残留垃圾**。
/// 归档(84) 的实锤：`P1 目标 App 进程状态=10750085536`（0x2_80C0_xxxx），
/// 于是「进程状态 ≥ 2 才算就绪」那扇门形同不存在 —— 目标 App 根本没启动也照样放行，
/// 第 4 步自然又是「四个 init 全 nil」，白跑一轮。
/// 返回 -1 = 取不到（对象为空 / 没有这个选择子 / 抛异常）。

/// 同上，`isFrontmost`（BOOL）—— Swift 侧用 KVC 读会拿到 nil，这里给个确定值。
/// 返回 -1 = 取不到。

/// V0.0.85（AevonEntityPidV85）：把一个选择子在**这个对象真实类**上的类型编码吐出来。
/// 用途：`processState` 连续两轮返回垃圾（10750085536 / -2127615328），
/// 说明我们按错误的返回类型读了它。有了编码就能确定该怎么读，不用再猜。
/// 返回 NULL 表示没有这个选择子。

