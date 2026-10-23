#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 真实修改「App 场景尺寸」（V0.0.55，AevonAdaptiveContentV55）。
///
/// 用户 Aevon(48) 第 2 条：「小窗比例正确了是小胖屏，但是内容依旧不显示底栏，
/// 所有内容应该根据窗口大小自适应显示内容，stheno 就是这样」。
///
/// 这才是正确做法，也是 Stheno 的做法 —— 逆向数据（Stheno.dylib）里同时出现：
///   · `_OBJC_CLASS_$_FBSMutableSceneSettings`
///   · `_OBJC_CLASS_$_UIMutableApplicationSceneSettings`
///   · `setFrame:`
///   · `updateSettings:withTransitionContext:completion:`
/// 也就是说 Stheno 并不是把整屏画面当图片缩放，而是把**场景的 frame 改小**，
/// 让 App 自己按新尺寸重新排版（和分屏 / 台前调度同一个机制）。
/// 这样顶栏、底栏、抖音右侧工具栏全都在，既没有黑边也没有裁切。
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
