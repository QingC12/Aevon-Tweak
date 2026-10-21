import Foundation

/// App 信息查询（SBApplicationController）。
enum AevonAppInfo {
    static func applicationController() -> AnyObject? {
        return AevonRuntime.sendClass("SBApplicationController", Selector(("sharedInstance")))
    }

    static func application(bundleID: String) -> AnyObject? {
        guard let controller = applicationController() else { return nil }
        return AevonRuntime.send(controller, Selector(("applicationWithBundleIdentifier:")),
                              argument: bundleID as NSString)
    }

    static func displayName(bundleID: String) -> String? {
        guard let app = application(bundleID: bundleID) else { return nil }
        return AevonRuntime.send(app, Selector(("displayName"))) as? String
    }

    static func pid(bundleID: String) -> Int? {
        guard let app = application(bundleID: bundleID) else { return nil }
        if let pid = AevonRuntime.int(app, Selector(("pid"))) { return pid }
        if let state = AevonRuntime.send(app, Selector(("processState"))) {
            return AevonRuntime.int(state, Selector(("pid")))
        }
        return nil
    }

    static func isRunning(bundleID: String) -> Bool {
        guard let app = application(bundleID: bundleID),
              let state = AevonRuntime.send(app, Selector(("processState"))) else { return false }
        return AevonRuntime.bool(state, key: "isRunning") ?? false
    }
}
