import Foundation

/// 基于 Objective-C 运行时的安全方法交换。
/// 不依赖 Orion / Substrate / Logos。
///
/// 安装后：
/// - 目标（实例/类）收到 `original` 选择子时，执行 `replacementClass` 中对应 sk_ 方法的代码；
/// - 在替换代码内部，把 self 强转到对应的 @objc 协议并调用同一个 sk_ 方法，
///   即可执行原始实现（等价 Logos 的 %orig）。
///
/// 安全要点：
/// 1. 若 `original` 是从父类继承的方法，先把继承到的实现复制到目标类再交换，
///    避免误改父类实现导致该父类的所有实例都被影响；
/// 2. 类或方法任一不存在时只记录日志并返回 false，不会崩溃；
/// 3. 替换方法使用唯一的 sk_ 前缀，永不与系统选择子冲突。
enum SKSwizzle {
    @discardableResult
    static func install(targetClassName: String,
                        original: Selector,
                        replacementClass: AnyClass,
                        replacement: Selector,
                        isClassMethod: Bool = false) -> Bool {
        guard let target = NSClassFromString(targetClassName) else {
            SKLog.warn("[hook] 类不存在，已跳过: \(targetClassName)")
            return false
        }
        let owner: AnyClass
        if isClassMethod {
            guard let metaclass = object_getClass(target) else {
                SKLog.warn("[hook] 无法获取元类: \(targetClassName)")
                return false
            }
            owner = metaclass
        } else {
            owner = target
        }
        return install(on: owner,
                       original: original,
                       replacementClass: replacementClass,
                       replacement: replacement,
                       targetDescription: targetClassName)
    }

    @discardableResult
    static func install(on owner: AnyClass,
                        original: Selector,
                        replacementClass: AnyClass,
                        replacement: Selector,
                        targetDescription: String? = nil) -> Bool {
        let name = targetDescription ?? NSStringFromClass(owner)

        guard let inherited = class_getInstanceMethod(owner, original) else {
            SKLog.warn("[hook] \(name) 没有方法 \(original)，已跳过")
            return false
        }
        guard let replacementImpl = class_getInstanceMethod(replacementClass, replacement) else {
            SKLog.warn("[hook] 替换方法 \(replacement) 不存在，已跳过")
            return false
        }

        // 关键安全步骤：若 original 继承自父类，先把父类实现复制一份到目标类。
        // （目标类已自行定义时 class_addMethod 会失败，无副作用。）
        class_addMethod(owner, original,
                        method_getImplementation(inherited),
                        method_getTypeEncoding(inherited))

        guard let originalMethod = class_getInstanceMethod(owner, original) else { return false }

        if class_getInstanceMethod(owner, replacement) == nil {
            let added = class_addMethod(owner, replacement,
                                        method_getImplementation(replacementImpl),
                                        method_getTypeEncoding(replacementImpl))
            if !added {
                SKLog.warn("[hook] 无法添加替换方法 \(replacement) 到 \(name)，已跳过")
                return false
            }
        }
        guard let replacementMethod = class_getInstanceMethod(owner, replacement) else { return false }

        method_exchangeImplementations(originalMethod, replacementMethod)
        SKLog.info("[hook] 已安装 \(name) \(original)")
        return true
    }
}
