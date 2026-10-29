import Foundation

/// Objective-C 运行时消息工具（不依赖 Orion / Substrate / Logos）。
/// 所有消息发送都先转换为 NSObject，再调用 perform / KVC，保证类型安全。
enum AevonRuntime {
    // MARK: - 实例变量

    /// 读取对象类型（@ 编码）实例变量；非对象类型 / 不存在时返回 nil。
    ///
    /// V0.1.7（AevonSafeIvarV107）：改成用 `object_getIvar` 取。
    /// 以前是「按 ivar 偏移自己 load 一个 AnyObject?」—— 那是把内存里的位子直接
    /// 当成对象指针交出去：只要那个槽是 weak / 未初始化 / 已经不是对象，
    /// 拿到的就是野指针，后续任何一次 `as?` 都会让进程在
    /// swift_dynamicCast → 消息转发 上直接死（归档(13) 两次自动注销的形态）。
    /// `object_getIvar` 是官方接口，会按 ARC 布局正确取值，不安全就返回 nil。
    static func ivarObject(_ object: AnyObject, _ name: String) -> AnyObject? {
        guard let cls = object_getClass(object),
              let ivar = class_getInstanceVariable(cls, name) else { return nil }
        guard let encoding = ivar_getTypeEncoding(ivar),
              String(cString: encoding).hasPrefix("@") else { return nil }
        guard let value = object_getIvar(object, ivar) else { return nil }
        return value as AnyObject
    }

    /// 读取字符串实例变量。
    ///
    /// 先确认值真的是字符串类，再做桥接 —— **绝不对来源不明的对象直接 `as? String`**。
    /// 类名判断走 ObjC 的 `AevonSafeClassName`（只查类名，不向对象发消息）。
    static func ivarString(_ object: AnyObject, _ name: String) -> String? {
        guard let value = ivarObject(object, name) else { return nil }
        guard let className = AevonSafeClassName(value), className.contains("String") else { return nil }
        return value as? String
    }

    /// 对象真实类名（用于日志诊断，取不到时返回 nil）。
    static func className(_ object: AnyObject) -> String? {
        guard let cls = object_getClass(object) else { return nil }
        return NSStringFromClass(cls)
    }

    // MARK: - 消息发送（非持有返回，适用于 getter / void 方法）

    /// 调用无参方法（getter）。返回非持有对象引用。
    static func send(_ target: AnyObject, _ selector: Selector) -> AnyObject? {
        guard let object = target as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    /// 调用带一个对象参数的方法。返回非持有对象引用（返回值可忽略）。
    @discardableResult
    static func send(_ target: AnyObject, _ selector: Selector, argument: Any?) -> AnyObject? {
        guard let object = target as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector, with: argument)?.takeUnretainedValue()
    }

    /// 调用带两个对象参数的方法。返回非持有对象引用（返回值可忽略）。
    @discardableResult
    static func send(_ target: AnyObject, _ selector: Selector, first: Any?, second: Any?) -> AnyObject? {
        guard let object = target as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector, with: first, with: second)?.takeUnretainedValue()
    }

    // MARK: - 消息发送（持有返回，适用于 alloc / init / mutableCopy）

    /// 对类对象发送 alloc，返回 +1 持有的新实例。
    /// 注意：不能用 `NSClassFromString(...) as? NSObject`——元类型到 NSObject 的条件转换恒失败。
    // MARK: - 类方法调用（+方法，接收者为类对象本身）

    /// 调用无参类方法（+方法），返回 +0 对象。
    static func sendClass(_ className: String, _ selector: Selector) -> AnyObject? {
        guard let cls = NSClassFromString(className),
              let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(cls, selector)
    }

    /// 调用带一个对象参数的类方法（+方法），返回 +0 对象。
    static func sendClass(_ className: String, _ selector: Selector, argument: Any?) -> AnyObject? {
        guard let cls = NSClassFromString(className),
              let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, Any?) -> AnyObject?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(cls, selector, argument)
    }

    /// 发送无参且返回 +1 持有对象的消息（init / mutableCopy）。
    static func sendOwned(_ target: AnyObject, _ selector: Selector) -> AnyObject? {
        guard let object = target as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeRetainedValue()
    }

    /// 发送带一个参数的 init 消息，返回 +1 持有对象。
    static func sendInit(_ target: AnyObject, _ selector: Selector, argument: Any?) -> AnyObject? {
        guard let object = target as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector, with: argument)?.takeRetainedValue()
    }

    /// 发送带两个参数的 init 消息，返回 +1 持有对象。
    static func sendInit(_ target: AnyObject, _ selector: Selector, first: Any?, second: Any?) -> AnyObject? {
        guard let object = target as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector, with: first, with: second)?.takeRetainedValue()
    }

    // MARK: - 标量

    /// 调用无参、返回 C 整型的方法（如 -pid）。通过 IMP 直接调用，避免 perform 误用标量。
    static func int(_ target: AnyObject, _ selector: Selector) -> Int? {
        guard target.responds(to: selector) else { return nil }
        guard let method = class_getInstanceMethod(object_getClass(target), selector) else { return nil }
        typealias IntFunction = @convention(c) (AnyObject, Selector) -> Int
        let function = unsafeBitCast(method_getImplementation(method), to: IntFunction.self)
        return function(target, selector)
    }

    /// KVC 安全读取布尔属性（先确认 getter 存在，避免 NSUndefinedKeyException）。
    static func bool(_ target: AnyObject, key: String) -> Bool? {
        guard let object = target as? NSObject else { return nil }
        guard object.responds(to: Selector(key)) else { return nil }
        if let number = object.value(forKey: key) as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// KVC 安全写入任意属性（先确认 setter 存在）。
    @discardableResult
    static func setValue(_ target: AnyObject, key: String, value: Any?) -> Bool {
        guard let object = target as? NSObject else { return false }
        let capitalized = key.prefix(1).uppercased() + key.dropFirst()
        let setter = Selector("set" + capitalized + ":")
        guard object.responds(to: setter) else { return false }
        object.setValue(value, forKey: key)
        return true
    }

    /// KVC 安全写入布尔属性。
    @discardableResult
    static func setBool(_ target: AnyObject, key: String, _ value: Bool) -> Bool {
        return setValue(target, key: key, value: value)
    }

    // MARK: - 带类型签名的消息调用（%orig 等价物 / 系统方法直调）

    /// 取方法实现；选择子不存在时返回 nil。
    private static func implementation(_ target: AnyObject, _ selector: Selector) -> UnsafeMutableRawPointer? {
        guard target.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(target), selector) else { return nil }
        return UnsafeMutableRawPointer(method_getImplementation(method))
    }

    /// 调用 void 方法（无参数）。
    static func sendVoid(_ target: AnyObject, _ selector: Selector) {
        guard let imp = implementation(target, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector)
    }

    /// 调用 void 方法（一个对象参数）。
    static func sendVoid(_ target: AnyObject, _ selector: Selector, _ a: Any?) {
        guard let imp = implementation(target, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Any?) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector, a)
    }

    /// 调用 void 方法（一个对象参数 + 一个 Bool 参数，如 launchApplicationWithIdentifier:suspended:）。
    static func sendVoid(_ target: AnyObject, _ selector: Selector, _ a: Any?, _ flag: Bool) {
        guard let imp = implementation(target, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Any?, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector, a, flag)
    }

    /// 调用 void 方法（两个对象参数）。
    static func sendVoid(_ target: AnyObject, _ selector: Selector, _ a: Any?, _ b: Any?) {
        guard let imp = implementation(target, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Any?, Any?) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector, a, b)
    }

    /// 调用 void 方法（UInt64 + 三个对象参数，如
    /// `UIApplicationSceneDeactivationManager _setDeactivationReasons:onScene:withSettings:reason:`，
    /// 类型编码 v48@0:8q16@24@32@40 —— Stheno 逆向数据同款签名）。
    static func sendVoid(_ target: AnyObject, _ selector: Selector, _ a: UInt64, _ b: Any?, _ c: Any?, _ d: Any?) {
        guard let imp = implementation(target, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64, Any?, Any?, Any?) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector, a, b, c, d)
    }

    /// 调用 void 方法（三个对象参数）。
    static func sendVoid(_ target: AnyObject, _ selector: Selector, _ a: Any?, _ b: Any?, _ c: Any?) {
        guard let imp = implementation(target, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Any?, Any?, Any?) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector, a, b, c)
    }

    /// 调用 void 方法（一个 Bool 参数，如 setForeground:）。
    static func sendVoidBool(_ target: AnyObject, _ selector: Selector, _ value: Bool) {
        guard let imp = implementation(target, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector, value)
    }

    /// 调用 void 方法（一个 UInt64 参数，如 setDeactivationReasons:）。
    /// 调用返回 +1 对象的 CGRect 入参方法（如 initWithFrame:）。
    static func sendInitFrame(_ target: AnyObject, _ selector: Selector, _ frame: CGRect) -> AnyObject? {
        guard let imp = implementation(target, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>
        return unsafeBitCast(imp, to: Fn.self)(target, selector, frame).takeRetainedValue()
    }

    /// 调用返回 +0 对象的无参方法（getter）。
}
