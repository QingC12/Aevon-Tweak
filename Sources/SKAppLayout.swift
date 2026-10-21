import Foundation

/// SBAppLayout 解析：从多任务卡片布局中取出 bundleID / 场景标识。
/// 覆盖 iOS 13–26 的多种内部结构（allItems / centerItem / rolesToLayoutItemsMap）。
enum SKAppLayout {
    static func bundleID(_ layout: AnyObject) -> String? {
        return items(layout).first.flatMap { itemString($0, "bundleIdentifier") }
    }

    static func sceneID(_ layout: AnyObject) -> String? {
        return items(layout).first.flatMap { itemString($0, "uniqueIdentifier") }
    }

    private static func items(_ layout: AnyObject) -> [AnyObject] {
        var result: [AnyObject] = []

        if layout.responds(to: Selector(("allItems"))),
           let all = SKRuntime.send(layout, Selector(("allItems"))) as? [AnyObject] {
            result.append(contentsOf: all)
        }
        if result.isEmpty, layout.responds(to: Selector(("centerItem"))),
           let center = SKRuntime.send(layout, Selector(("centerItem"))) {
            result.append(center)
        }
        if result.isEmpty,
           let map = SKRuntime.ivarObject(layout, "_rolesToLayoutItemsMap") as? [Any: AnyObject] {
            result.append(contentsOf: map.values)
        }
        return result
    }

    private static func itemString(_ item: AnyObject, _ selector: Selector) -> String? {
        guard item.responds(to: selector) else { return nil }
        return SKRuntime.send(item, selector) as? String
    }
}
