#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// ── V0.2.13（AevonSysEdgeV213）：右缘呼出改走「系统手势管线（withType 接口）」──
///
/// 为什么重开这条路：
///   0.1.5~0.1.13 试过 `_UISystemGestureManager -addGestureRecognizer:toDisplayWithIdentity:`，
///   登记是成功的（Aevon(76) 日志），但当时用 `UIPanGestureRecognizer` + `delaysTouchesBegan=YES`
///   + 手动补投来归还触摸，而「扣住 began 再按序补投」在 0.1.19 被判定不可做
///   （补投时 phase 已是 Moved，App 永远收不到 Began）—— 于是 0.1.13 起整条停手。
///
///   本轮换了三件事，这条路的失败前提全部变了：
///   ① 识别器换成 `UIScreenEdgePanGestureRecognizer`（**系统自己的边缘识别器**），
///      它自带「从边缘起手 / 向内移动」的判定，失败时由 UIKit 自己把触摸还给 App，
///      **不需要我们补投任何一帧**；
///   ② 登记接口换成 `-addGestureRecognizer:withType:` —— 真机探针（Aevon(75)）只测过
///      `toDisplayWithIdentity:`，**这个带 type 的接口从未被验证过**，而 Triggr 用的正是它；
///   ③ 触摸策略回到 UIKit 默认值（`cancelsTouchesInView=YES` / `delaysTouchesBegan=NO`），
///      也就是 Apple 自己给左缘返回手势用的那套 —— 先给 App began，识别成功再 cancel。
///
/// 失败一律静默返回 NO / nil，调用方据此回退 0.2.12 的老通道（全局通道 + 热区）。

/// 造一个右缘系统识别器。
/// @param type 传给私有 init 的类型编号；Triggr 实测 `2`（= SpringBoard 自己的编号）可用。
/// @param edgeRegionSize 边缘区宽度（pt）；<=0 表示不调用 `_setEdgeRegionSize:`，用系统默认。
/// @return 识别器；返回 nil 表示该类不支持私有 init（此时调用方应放弃本通道）。
UIGestureRecognizer *AevonSysEdgeCreateRecognizer(id target, SEL action,
                                                  NSInteger type, double edgeRegionSize);

/// 把识别器登记进系统手势管线。
/// 顺序：`SBSystemGestureManager -addGestureRecognizer:withType:` 优先，
/// 其次 `-addGestureRecognizer:toDisplayWithIdentity:`，最后退到单参 `-addGestureRecognizer:`。
/// @return YES 表示至少一条路径成功；成功后 `AevonSysEdgeLastRegisterPath()` 给出走了哪条。
BOOL AevonSysEdgeRegister(UIGestureRecognizer *recognizer, unsigned long long type);

/// 上一次登记实际走的路径（用于日志；未登记时返回空串）。
NSString *AevonSysEdgeLastRegisterPath(void);

/// 让自编 type 被系统放行：swizzle `SBSystemGestureManager` 的
/// `-_isGestureWithTypeAllowed:` 与 `-_shouldEnableSystemGestureWithType:`。
/// 不改原实现，只对 base ~ base+count 这个区间返回 YES，其余原样转交。
/// @return YES 表示至少挂上一个（两个都挂不上时自编 type 可能被忽略，日志会写明）。
BOOL AevonSysEdgeAllowTypes(unsigned long long base, unsigned long long count);

/// 强制把一个识别器置为 Failed（= 归还触摸）。
///
/// 为什么不能直接在 Swift 里写 `gesture.state = .failed`：
/// `UIGestureRecognizer.state` 在 Swift 侧是**只读**属性（只有子类内部能改），
/// 而本项目的策略层是 Swift、识别器是系统的 `UIScreenEdgePanGestureRecognizer`，
/// 没有子类可写。只能回到 ObjC 走私有的 `-setState:`。
void AevonSysEdgeForceFail(UIGestureRecognizer *recognizer);
