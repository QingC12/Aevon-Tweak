#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 真实修改「App 场景尺寸」（V0.0.55，AevonAdaptiveContentV55）。
///
/// 用户 Aevon(48) 第 2 条：「小窗比例正确了是小胖屏，但是内容依旧不显示底栏，
/// 所有内容应该根据窗口大小自适应显示内容，stheno 就是这样」。
///
/// V0.0.55 的教训（AevonSceneSetFrameSize）：只把 settings.frame 改小是**不够的** ——
/// 真机日志证明场景 267×458 生效了，但那只是**渲染视口**：App 的 UIWindow 仍是
/// 430×932，内容照旧按整屏排版，视口只露出左边 62%（字变大、右边被切）。
///
/// V0.0.59（AevonTrueResizeV59）按 Mango（com.go.mango 1.0-Beta8）的逆向实证补齐：
///   · `mangoDisplayConfigForFrame:` 把帧换算成 **UIDisplayConfiguration**
///     写进场景设置（`displayConfiguration` / `setDisplayConfiguration:` 字符串实锤）；
///   · displayConfiguration 在 settings 里**随帧一起**经官方 diff 通道下发，
///     App 进程收到后自己的 UIWindow / 布局尺寸才会真的变 —— 这就是
///     「底栏/顶栏/右侧工具栏原生在场」的机制；
///   · 顺带 Stheno 同款 `setResizesHostedContext:`（托管上下文可 resize 开关）。
/// 三路杠杆每一路都独立记录结果（位掩码返回），真机日志能直接看出哪一路生效。
///
/// 全程 @try/@catch：改的是别的进程的场景设置，绝不能把异常抛回 SpringBoard。

/// 读场景当前 frame 尺寸（拿不到返回 CGSizeZero）。
CGSize AevonSceneFrameSize(id scene);

/// 把场景 frame 改成指定尺寸，并推一次 settings 更新。
/// 返回 YES = 系统读回来的尺寸与目标一致（证明确实生效）。
BOOL AevonSceneSetFrameSize(id scene, CGSize size);

/// 直接在 settings 对象上写 frame —— 供 FBScene 的
/// `updateSettings:withTransitionContext:completion:` 钩子使用：
/// 系统每次推新 settings 都把尺寸改回来，避免被 SpringBoard 重置成整屏。
BOOL AevonSettingsSetFrame(id settings, CGRect frame);

/// 类是否真的支持 frame（日志用：能区分「API 不存在」与「写入失败」）。
BOOL AevonSceneFrameSupported(id scene);

/* ── V0.0.59（AevonTrueResizeV59）：帧 + 显示配置一起下发 ── */

// 结果位掩码（Swift 侧按位打日志）：
//   0x01 frame 写入成功
//   0x02 旧 displayConfiguration 读到了
//   0x04 displayConfiguration 尺寸写入成功（size / _size 通道）
//   0x08 displayConfiguration 尺寸写入成功（sizeInPoints / _sizeInPoints 通道）
//   0x10 setDisplayConfiguration: 下发成功
//   0x20 setResizesHostedContext: 接受（YES）
//   0x40 updateSettings diff 通道接受
//   0x80 回读 frame 与目标一致
// V0.0.60（AevonReflowGateV60）新增写入策略位：
//   0x100 策略=旧配置拷贝 / 0x200 策略=原对象直写 / 0x400 策略=新建配置
// 硬闸门：displayConfiguration 写不进 → 只返回 0x02+策略诊断位，
//         **不写 frame、不推 diff**（V55 教训：单推 frame = 裁视口 = 内容放大显示不全）。
int AevonSceneApplyDisplaySize(id scene, CGSize size, BOOL floatMode);

/// 最近一次 displayConfiguration 诊断串（类名 + 能力表），供日志使用。
const char *AevonDisplayConfigDiag(void);

/// 读场景 displayConfiguration 里的尺寸（拿不到返回 CGSizeZero，仅诊断用）。
CGSize AevonSceneDisplaySize(id scene);

/// 在（可变）settings 上把 displayConfiguration 尺寸顶到目标 —— FBScene 钩子用。
BOOL AevonSettingsApplyDisplaySize(id settings, CGSize size);

/// V0.0.64（AevonReflowAppGateV64）：scene 方法表诊断（host/Context/resize 选择子
/// + context 类键取值），只在首次 AevonSceneApplyDisplaySize 时 dump 一次。
const char *AevonSceneMethodDiag(void);

#pragma mark - V0.0.75（AevonCrashFuseV75）：P1 自建场景的崩溃防护三件套

/// 安全取类名（obj 为 nil → "nil"）。
///
/// Aevon(67) 自动注销的根因：Swift 里 `String(describing: type(of: obj))` 对一个
/// **不是合法对象**的指针（典型来源：`perform:` 调用返回 BOOL 的方法，返回值 1
/// 被当成对象指针）会读 isa → 野指针 → SIGSEGV/SIGTRAP，SpringBoard 直接退出。
/// Swift 的 `type(of:)` / `String(describing:)` 都会走 swift_getObjectType，
/// 这里改用纯 ObjC runtime 读类指针，**绝不触发 Swift 元类型机制**。
NSString *AevonSafeClassName(id obj);

/// 安全调用返回 BOOL 的方法/属性。
/// `ok` 回填「确实调用成功且返回类型是 BOOL」，调用方据此决定是否采信。
/// 内部先查方法签名返回值编码，绝不把 BOOL 当对象指针用。
BOOL AevonSafeBoolCall(id obj, NSString *selectorName, BOOL *ok);

/// 面包屑：P1 每进入一步前写一行（< 64 字节），走完清空。
/// 启动时若读到残留 → 说明上一轮 P1 把进程搞崩了（respring 不会清文件）。
void AevonCrumbWrite(const char *stage);
/// 读残留面包屑（无则返回 ""，指针常驻，勿 free）。
const char *AevonCrumbRead(void);
/// 清空面包屑（正常结束 / 熔断处理后调用）。
void AevonCrumbClear(void);

/// 安全调用「返回对象」的无参方法：**先查返回值编码首字符是否为 '@'**，
/// 不是（BOOL / 整数 / 结构体）直接返回 nil —— 这是 Aevon(67) 自动注销的另一半根因：
/// `perform:` + `takeUnretainedValue()` 会把 BOOL 返回值 1 包装成对象指针，
/// Swift 的 `as? NSObject` 随即 dynamicCast 读野 isa 崩溃。
/// 走这条路之后，Swift 侧不再有任何「猜返回值类型」的机会。
id AevonSafeCallObject(id obj, NSString *selectorName);
/// 同上，带 1 个对象参数（等价 performSelector:withObject:）。
id AevonSafeCallObject1(id obj, NSString *selectorName, id arg1);
/// 同上，带 2 个对象参数（等价 performSelector:withObject:withObject:）。
id AevonSafeCallObject2(id obj, NSString *selectorName, id arg1, id arg2);
/// 安全读对象型 ivar（类型编码必须是 '@'，否则返回 nil）。
id AevonSafeReadObjectIvar(id obj, const char *ivarName);
