import UIKit

/// 启动引导：只用通知监听，不做任何系统方法交换。
///
/// V0.0.7 的核心安全设计：
/// 入口（悬浮球）完全靠 UIApplication 的生命周期通知驱动，
/// 启动阶段 SpringBoard 的系统方法上一个 hook 都没有，
/// 因此不可能再出现「长按图标 → 注销」这类系统路径崩溃。
enum AevonBootstrap {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default

        // 启动完成 → 等 4 秒（让桌面把图标、Widget 都铺好）再挂悬浮球
        _ = center.addObserver(forName: UIApplication.didFinishLaunchingNotification,
                               object: nil,
                               queue: .main) { _ in
            AevonLog.info("[引导] 收到 didFinishLaunching，4 秒后创建悬浮球")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                AevonBubble.shared.install(attempt: 1, reason: "didFinishLaunching")
            }
        }

        // 兜底：每次回到活跃态时检查一遍（悬浮球被系统回收/首次没有场景时补建）
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil,
                               queue: .main) { _ in
            guard !AevonBubble.shared.isVisible else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AevonBubble.shared.install(attempt: 1, reason: "didBecomeActive")
            }
        }

        AevonLog.info("[引导] 已注册启动通知（入口不依赖任何 hook）")
    }
}
