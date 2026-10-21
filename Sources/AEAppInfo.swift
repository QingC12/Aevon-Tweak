import Foundation

/// App 信息查询（SBApplicationController）。
enum AEAppInfo {
    static func applicationController() -> AnyObject? {
        return AERuntime.sendClass("SBApplicationController", Selector(("sharedInstance")))
    }

    static func application(bundleID: String) -> AnyObject? {
        guard let controller = applicationController() else { return nil }
        return AERuntime.send(controller, Selector(("applicationWithBundleIdentifier:")),
                              argument: bundleID as NSString)
    }

    static func displayName(bundleID: String) -> String? {
        guard let app = application(bundleID: bundleID) else { return nil }
        return AERuntime.send(app, Selector(("displayName"))) as? String
    }

    static func pid(bundleID: String) -> Int? {
        guard let app = application(bundleID: bundleID) else { return nil }
        if let pid = AERuntime.int(app, Selector(("pid"))) { return pid }
        if let state = AERuntime.send(app, Selector(("processState"))) {
            return AERuntime.int(state, Selector(("pid")))
        }
        return nil
    }

    static func isRunning(bundleID: String) -> Bool {
        guard let app = application(bundleID: bundleID),
              let state = AERuntime.send(app, Selector(("processState"))) else { return false }
        return AERuntime.bool(state, key: "isRunning") ?? false
    }
}
