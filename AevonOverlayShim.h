#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 覆盖层可见性探测（V0.0.55，AevonOverlayPolicyV55）。
///
/// 用户 Aevon(48) 第 5 条：「如果开启悬浮窗时锁屏，亮屏后锁屏页面中间会显示黑屏的主悬浮窗
/// （应该是悬浮窗只在桌面和全屏 App 中显示，而不是在锁屏、控制中心、通知中心显示）」。
///
/// 为什么必须主动探测：入口窗口的 level 是 1e7，比系统自己的
/// `SBCoverSheetWindow`（1050）/ `SBControlCenterWindow`（1080）高得多 ——
/// Aevon(48) 的诊断行把这条窗口栈完整打出来了。所以锁屏、控制中心、通知中心一旦出现，
/// 我们的窗口一定会盖在它们上面；系统不会替我们隐藏。
///
/// 这里只做「读」，不改任何系统状态。

/// 锁屏 / 通知中心 / 控制中心的承载窗口是否正在显示。
/// 三者都用 SpringBoard 自己的窗口承载，正常使用时它们是 hidden 的
/// （日志里显示为 `SBCoverSheetWindow(h)`），一旦可见就说明用户进了这些界面。
BOOL AevonOverlayCoverSheetVisible(void);

/// App 切换器（后台卡片）是否正在显示。
/// 优先问 `SBMainSwitcherControllerCoordinator`；拿不到时退回扫描窗口类名。
BOOL AevonOverlaySwitcherVisible(void);

/// 给日志用：当前可见的「需要隐藏浮窗」的窗口类名列表（没命中返回空串）。
NSString *AevonOverlayVisibleOverlayNames(void);
