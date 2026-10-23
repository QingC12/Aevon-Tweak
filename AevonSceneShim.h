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
//   bit0  frame 写入成功
//   bit1  旧 displayConfiguration 读到了
//   bit2  displayConfiguration 尺寸写入成功（size 键）
//   bit3  displayConfiguration 尺寸写入成功（sizeInPoints 键）
//   bit4  setDisplayConfiguration: 下发成功
//   bit5  setResizesHostedContext: 接受（YES）
//   bit6  updateSettings diff 通道接受
//   bit7  回读 frame 与目标一致
int AevonSceneApplyDisplaySize(id scene, CGSize size, BOOL floatMode);

/// 读场景 displayConfiguration 里的尺寸（拿不到返回 CGSizeZero，仅诊断用）。
CGSize AevonSceneDisplaySize(id scene);

/// 在（可变）settings 上把 displayConfiguration 尺寸顶到目标 —— FBScene 钩子用。
BOOL AevonSettingsApplyDisplaySize(id settings, CGSize size);
