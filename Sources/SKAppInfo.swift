import Foundation

/// App 信息查询（SBApplicationController）。
enum SKAppInfo {
    static func applicationController() -> AnyObject? {
        return SKRuntime.sendClass("SBApplicationController", Selector(("sharedInstance")))
    }

    static func application(bundleID: String) -> AnyObject? {
        guard let controller = applicationController() else { return nil }
        return SKRuntime.send(controller, Selector(("applicationWithBundleIdentifier:")),
                              argument: bundleID as NSString)
    }

    static func displayName(bundleID: String) -> String? {
        guard let app = application(bundleID: bundleID) else { return nil }
        return SKRuntime.send(app, Selector(("displayName"))) as? String
    }

    static func pid(bundleID: String) -> Int? {
        guard let app = application(bundleID: bundleID) else { return nil }
        if let pid = SKRuntime.int(app, Selector(("pid"))) { return pid }
        if let state = SKRuntime.send(app, Selector(("processState"))) {
            return SKRuntime.int(state, Selector(("pid")))
        }
        return nil
    }

    static func isRunning(bundleID: String) -> Bool {
        guard let app = application(bundleID: bundleID),
              let state = SKRuntime.send(app, Selector(("processState"))) else { return false }
        return SKRuntime.bool(state, key: "isRunning") ?? false
    }
}
