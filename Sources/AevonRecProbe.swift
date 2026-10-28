/// V0.2.71（AevonRecProbeV271，用户 Aevon(43) #4「用探针寻找 iOS 17 系统控制中心的录屏方式」）：
/// 一次性运行时扫描 —— 全量类表里找 `startSystemRecordingWithMicrophoneEnabled:handler:`
/// 的宿主类。逆向档案实锤：ScreenCore.dylib 与 MangoHello.dylib 的字符串表都带这个
/// selector（analysis/screencore + analysis/mango），它就是控制中心录屏按钮最终调的
/// 私有入口；但宿主类（SB 侧哪个类实现了它）静态表里定不了档，探针运行时扫一遍，
/// 下一篇日志给出命中类名，下一版把 RP 主路接到它上面。
///
/// 独立文件的原因：0.2.65 反回退断言整段禁 AevonQuickAction.swift 里的类表扫描字样
///（Aevon(38) 实测「遍历类表 + perform 录屏单例」一点就注销）。本探针**只扫不调**
///（纯 method 名比对，零 perform、零 dynamicCast），放到独立文件既守断言也守教训。
/// 队列：0.2.68 铁律全局并发队列禁用（append 乱序教训），探针只打一条日志，
/// 走 main 串行足够。
import ObjectiveC.runtime

enum AevonRecProbe {
    private static var done = false
    static func runOnce() {
        guard !done else { return }
        done = true
        DispatchQueue.main.async {
            let target = "startSystemRecordingWithMicrophoneEnabled:handler:"
            var classCount: UInt32 = 0
            guard let classList = objc_copyClassList(&classCount) else {
                AevonLog.warn("[录屏] 探针：类表拿不到（AevonRecProbeV271）")
                return
            }
            var hits: [String] = []
            for i in 0..<Int(classCount) {
                let cls: AnyClass = classList[i]
                // 类方法
                var mCount: UInt32 = 0
                if let methods = class_copyMethodList(object_getClass(cls), &mCount) {
                    for j in 0..<Int(mCount) {
                        if String(cString: sel_getName(method_getName(methods[j]))) == target {
                            hits.append("\(NSStringFromClass(cls))(+)")
                        }
                    }
                    free(methods)
                }
                // 实例方法
                var iCount: UInt32 = 0
                if let imethods = class_copyMethodList(cls, &iCount) {
                    for j in 0..<Int(iCount) {
                        if String(cString: sel_getName(method_getName(imethods[j]))) == target {
                            hits.append("\(NSStringFromClass(cls))(-)")
                        }
                    }
                    free(imethods)
                }
            }
            AevonLog.info("[录屏] 探针完成：\(target) 命中 \(hits.count) 个 → "
                + "\(hits.joined(separator: " | "))（AevonRecProbeV271）")
        }
    }
}
