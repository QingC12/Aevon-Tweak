import UIKit

/// 停靠侧别（V0.2.50，AevonDockColumnV250）。
enum AevonDockSide: String {
    case left
    case right

    var opposite: AevonDockSide {
        return self == .left ? .right : .left
    }

    var title: String {
        return self == .left ? "左" : "右"
    }
}

/// 屏幕左右边缘的停靠列（吸附小窗）几何 + 槽位分配。
///
/// 历史与依据
/// ----------
/// 用户 Aevon(25) 第 3 条：「更新一下屏幕左右边缘的吸附停靠小窗……小窗吸附后的尺寸
/// 按照我们的小胖屏等比例缩小，具体大小查看之前视频中的数据，吸附小窗的停靠位置
/// 优先从顶部开始，依次向下排列」。
///
/// 「之前视频中的数据」= 本项目 V0.0.50~V0.0.57 那一代真机定档过的停靠列：
///   · 顶部锚点 = 屏高 × 10%（`dockTopRatio`，用户当时原话「第一个小窗在屏幕右上角，
///     距离顶部 10% 处」）；
///   · 一列最多 5 个（`dockMaxCount`，原话「总数量只有 5 个」）；
///   · 间距 8pt、底部留 16pt（home indicator）；
///   · 单窗尺寸**不是**拍脑袋定的，而是「5 格必须排得下」反算出来的高度上限，
///     再按比例反推宽度 —— 这样无论机型多矮，5 个一定完整落在屏内。
/// 这一版把比例从当年的 9:16 / 0.60 换成当前的**小胖屏 7:12（0.5833）**，
/// 于是「等比例缩小」在数值上就是：宽度 = 高度 × 0.5833。
///
/// iPhone 15 Pro Max（430×932）实算：
///   顶部 93.2 + 底部留 16 → 可用 822.8；5 格 + 4 道缝（8pt）→ 单格高 158.2；
///   宽 = 158.2 × 0.5833 ≈ 92.3 → **92 × 158**（主窗 344×590 的 27% 宽、27% 高，
///   即等比例缩到 0.27 倍）。这就是「按小胖屏等比例缩小」的落地值。
enum AevonDock {
    /// 一列最多几个（V0.0.50 用户定档：5 个）
    static let maxCount = 5
    /// 相邻两格之间的缝
    static let gap: CGFloat = 8
    /// 第 1 格顶边 = 屏高 × 10%
    static let topRatio: CGFloat = 0.10
    /// 最后一格不压到底（home indicator）
    static let bottomMargin: CGFloat = 16
    /// 宽度绝对下限：低于这个值连图标都看不清，宁减少格数
    static let minWidth: CGFloat = 56
    /// 贴边时的外沿留白（用户 Aevon(41) 定档：直接贴边 = 0）
    static let edgeInset: CGFloat = 0

    /// 停靠小窗尺寸（宽, 高）—— 5 格反算，全列共用同一个尺寸。
    static var size: CGSize {
        let screen = UIScreen.main.bounds
        let aspect = max(0.2, AevonWindowView.contentAspectCurrent)
        guard screen.width > 1, screen.height > 200 else {
            let width = max(minWidth, 92)
            return CGSize(width: width, height: width / aspect)
        }
        let top = screen.height * topRatio
        let available = max(160, screen.height - top - bottomMargin)
        let gaps = gap * CGFloat(max(1, maxCount - 1))
        let maxHeight = (available - gaps) / CGFloat(max(1, maxCount))
        var height = floor(maxHeight)
        var width = floor(height * aspect)
        if width < minWidth {
            width = minWidth
            height = floor(width / aspect)
        }
        // 宽不能超过屏宽的一半（再宽就不是「小窗」了）
        let widthCap = floor(screen.width * 0.5)
        if width > widthCap {
            width = widthCap
            height = floor(width / aspect)
        }
        return CGSize(width: width, height: height)
    }

    /// 某一格的 frame（屏幕坐标）。
    static func frame(side: AevonDockSide, index: Int) -> CGRect {
        let screen = UIScreen.main.bounds
        let slot = size
        let top = floor(screen.height * topRatio)
        let y = top + CGFloat(max(0, index)) * (slot.height + gap)
        let x: CGFloat = (side == .left) ? edgeInset : (screen.width - slot.width - edgeInset)
        return CGRect(x: x, y: y, width: slot.width, height: slot.height)
    }

    /// 这个点算不算「想停靠到某一侧」（松手时判定，左右各 26pt 内）。
    static let dropThreshold: CGFloat = 26

    static func side(forDropAt frame: CGRect) -> AevonDockSide? {
        let screen = UIScreen.main.bounds
        guard screen.width > 1 else { return nil }
        if frame.minX <= dropThreshold { return .left }
        if frame.maxX >= screen.width - dropThreshold { return .right }
        return nil
    }

    /// 主窗从停靠态还原时的目标几何（沿用主窗的几何记忆，夹屏后返回）。
}
