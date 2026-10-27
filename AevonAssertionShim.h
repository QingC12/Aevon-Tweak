#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 偏好写入（在 Objective-C 中调用 CFPreferences，规避 Swift 对 CFPropertyListRef 的类型推断歧义）。
/// 读写域与设置界面（Preferences.framework）一致：com.Aevon。
void AevonPrefSetBool(NSString *key, BOOL value);
void AevonPrefSetInt(NSString *key, NSInteger value);
void AevonPrefSetDouble(NSString *key, double value);
/// V0.2.9（AevonFloatStandDownV209）：字符串写入（浮窗里装的是哪个 App，App 侧要能读到）。
/// 传 nil / 空串等价于删除该键 —— App 侧读到空串就知道「我不在浮窗里」。
void AevonPrefSetString(NSString *key, NSString *value);

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
/// V0.2.20（AevonAppGeomNotifyV220）：右缘带几何 → 共享内存 bit48-63
/// （48-55 = 带宽 pt，56-63 = 带高 %；0 = 未发布）。读-改-写保留 zone/enabled/ring/版本位。
/// App 侧只认这里 —— 沙盒 App 读不到 com.Aevon 域（Aevon(105)：抖音按 fallback
/// 46pt×60% 误判几何，「屏幕 50% 呼出圆盘」），notify 状态是沙盒里验证多年的通道。
void AevonNotifySetBand(double w, double h);
/// V0.2.49（AevonAppScreenFitV249）：把「浮窗里装的是哪个 App」发到共享内存。
/// 单开一个 notify 名字 `com.aevon.floatstage`，state = bundleID 的 FNV-1a 32 位散列
/// （0 = 没有浮窗）。App 侧据此决定要不要把 `UIScreen.bounds` 报成画布尺寸 ——
/// 走 notify 而不是偏好域，是因为沙盒最严的 App（抖音）读不到 com.Aevon。
void AevonNotifySetFloatStage(NSString *bundleID);
/// V0.2.12（AevonAppRingGoneGuardV212）：读圆盘状态位。返回 1 = 圆盘正展开，0 = 已收起。
///
/// 为什么 App 侧必须能读：Aevon(98) 事故里 App 识别器停在 .began 之后，抬手帧被
/// SpringBoard 吞掉（那是它的职责），Darwin 的 ringclose 通知也可能没送到 ——
/// 唯一不依赖任何事件、任何时序的判据就是这个共享内存位。App 侧轮询它，
/// 只要「圆盘已收起 + 我还在 .began」就立刻收尾，卡死结构上不可能发生。
int AevonNotifyGetRing(void);

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
