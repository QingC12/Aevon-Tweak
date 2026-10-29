import UIKit

/// App 原生图标（V0.0.22）。
///
/// 取图逻辑全在 ObjC 垫片 `AevonIconImage`（SBIconModel → 包内 PNG → UIImage 私有接口 → 旧接口），
/// 这里只做两件事：按目标尺寸缩放成圆角方形、按 bundleID 缓存（面板滚动时不会反复取图）。
/// 取不到就返回 nil —— 调用方必须准备文字兜底，绝不因为图标缺失而影响功能。
enum AevonAppIcon {
    private static var cache: [String: UIImage] = [:]
    private static var failed = Set<String>()

    static func image(bundleID: String, size: CGFloat) -> UIImage? {
        if bundleID.isEmpty { return nil }
        if let cached = cache[bundleID] { return cached }
        if failed.contains(bundleID) { return nil }
        let raw = AevonIconImage(bundleID, 3.0)
        guard let source = raw, source.size.width > 0, source.size.height > 0 else {
            failed.insert(bundleID)
            return nil
        }
        let scaled = resize(source, size: size)
        cache[bundleID] = scaled
        return scaled
    }

    /// 坐标系重置（App 列表强刷时调用，允许重新尝试之前失败的图标）
    private static func resize(_ image: UIImage, size: CGFloat) -> UIImage {
        let target = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: target)
            // iOS 图标观感：圆角约 22.37%
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.2237).addClip()
            image.draw(in: rect)
        }
    }
}
