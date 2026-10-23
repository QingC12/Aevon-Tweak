#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <signal.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

/*
 * RBSAssertion 保活垫片（Objective-C，异常安全）。
 *
 * 为什么用 ObjC：RBSAssertion / RBSTarget / RBSLegacyAttribute 均为私有框架类，
 * 且 acquireWithError: 内部可能抛出 ObjC 异常；Swift 无法捕获 ObjC 异常，
 * 因此单独放在 ObjC 文件中用 @try/@catch 兜底，保证任何失败都不会影响主流程。
 */

static CFStringRef AevonPrefsAppID(void) {
    return CFSTR("com.Aevon");
}

/* V0.0.30：CI 校验标记。
 * 面板去掉「左右分屏」档后 openSplit 暂无调用方，Swift/LLVM 会把无人调用的函数
 * 连同其内部的字符串常量一起消除（V0.0.29 里靠面板调用链保活，现在断了），
 * Swift 侧的常量引用也会被常量折叠/死代码消除 —— 只有 ObjC 的 used 属性能强制
 * 保留。分屏流程代码本身保留，后续版本复用。 */
__attribute__((used)) static const char AevonSplitFlowCIMarker[] = "AevonSplitFlow";

/* V0.0.31 CI 标记：Swift 侧字符串可能被常量折叠/死代码消除，统一用 ObjC used 兜底 */
__attribute__((used)) static const char AevonRingSquareV31Marker[] = "AevonRingSquareV31";
__attribute__((used)) static const char AevonRingAutoSizeV31Marker[] = "AevonRingAutoSizeV31";
__attribute__((used)) static const char AevonRingPinnedV31Marker[] = "AevonRingPinnedV31";
__attribute__((used)) static const char AevonGuardFileConfV31Marker[] = "AEVONGUARDCONFV31";

/* V0.0.32 CI 标记：notify(3) 跨进程热区通道（沙盒 App 唯一可靠的配置来源） */
__attribute__((used)) static const char AevonGuardNotifyV32Marker[] = "AevonGuardNotifyV32";

/* V0.0.33 CI 标记：热区按下无条件接管 + 圆盘速度弹簧 + Guard 圆盘期吞区加宽 */
__attribute__((used)) static const char AevonTouchOwnV33Marker[] = "AevonTouchOwnV33";
__attribute__((used)) static const char AevonRingSpringV33Marker[] = "AevonRingSpringV33";
__attribute__((used)) static const char AevonGuardRingWideV33Marker[] = "AevonGuardRingWideV33";

/* V0.0.34 CI 标记：圆盘状态走 notify(3) 共享内存位（沙盒 App 零时序依赖） */
__attribute__((used)) static const char AevonNotifyRingBitV34Marker[] = "AevonNotifyRingBitV34";

/* V0.0.35 CI 标记：Guard 全 App 注入（UIKit bundle filter）+ ack 回执 + hover 向上跳跃 */
__attribute__((used)) static const char AevonGuardUIKitV35Marker[] = "AevonGuardUIKitV35";
__attribute__((used)) static const char AevonGuardAckV35Marker[] = "AevonGuardAckV35";
__attribute__((used)) static const char AevonRingHopV35Marker[] = "AevonRingHopV35";

/* V0.0.36 CI 标记：浮窗外壳搬进入口容器（单窗口化）+ 四周 8 向缩放手势 */
__attribute__((used)) static const char AevonFloatInEntryV36Marker[] = "AevonFloatInEntryV36";
__attribute__((used)) static const char AevonEdgeResizeV36Marker[] = "AevonEdgeResizeV36";

/* V0.0.37 CI 标记：
 * AevonDeactivationGateV37 = 场景停用门控（UIApplicationSceneDeactivationManager，
 *                            Stheno 同款，全屏 App 里浮窗可交互的根治）；
 * AevonSthenoEdgeBarV37    = 浮窗 Stheno 外侧边缘手势（边缘条在窗外，不占窗内）；
 * AevonMedusaFrameV37      = 浮窗几何全局记忆（Stheno medusaFrameLast 百分比方案）。
 * 浮窗尺寸/位置设置项（AevonFloatPrefV36）已按需求移除。 */
__attribute__((used)) static const char AevonDeactivationGateV37Marker[] = "AevonDeactivationGateV37";
__attribute__((used)) static const char AevonSthenoEdgeBarV37Marker[] = "AevonSthenoEdgeBarV37";
__attribute__((used)) static const char AevonMedusaFrameV37Marker[] = "AevonMedusaFrameV37";

/* V0.0.38 CI 标记：
 * AevonOutsideHitV38 = 外侧手势命中修复（pointInside 扩成「窗口 bounds ∪ 手柄」，
 *                      根治窗外边条/外角块命中不到 → 移动/缩放全失效）；
 * AevonSwipeOnlyV38  = 触发条长按呼出已移除，只保留左滑。 */
__attribute__((used)) static const char AevonOutsideHitV38Marker[] = "AevonOutsideHitV38";
__attribute__((used)) static const char AevonSwipeOnlyV38Marker[] = "AevonSwipeOnlyV38";

/* V0.0.40：崩溃归因（外部模块崩溃不再误禁 Aevon）+ Sileo 图标纯路径 */
__attribute__((used)) static const char AevonCrashAttrV40Marker[] = "AevonCrashAttrV40";
__attribute__((used)) static const char AevonSileoIconV40Marker[] = "AevonSileoIconV40";

/* V0.0.41 CI 标记：
 * AevonFloatGlobalV41 = 浮窗移动/缩放/关闭/双击改由全局触摸通道驱动
 *                      （全屏 App 里视图层命中不到窗外手柄，Aevon(34) 根因）。 */
__attribute__((used)) static const char AevonFloatGlobalV41Marker[] = "AevonFloatGlobalV41";

/* V0.0.42 CI 标记：
 * AevonSthenoDockV42 = 停靠（吸附）改为 Stheno 式「只靠边不改尺寸」+ 四边恒定避让
 *                      34pt（外角块），根治吸附成巨窗后四角出屏、无法缩放；
 * AevonFloatLookV42  = 观感复刻：圆角随缩放同比（_displayCornerRadius 系）+ 投影 + 细描边。 */
__attribute__((used)) static const char AevonSthenoDockV42Marker[] = "AevonSthenoDockV42";
__attribute__((used)) static const char AevonFloatLookV42Marker[] = "AevonFloatLookV42";

/* V0.0.43 CI 标记（AevonSthenoGestureV43）：
 * 按 Stheno 主浮窗 1:1 复刻几何与手势 ——
 *   · 贴边距离 34pt → 5pt（Stheno 浮窗是贴着屏幕边的，没有大空白）；
 *   · 默认窗宽 70% → 55%，停靠尺寸固定为 50% 屏宽的小窗；
 *   · 顶部（顶边条 + 上角块 + 右上 ✕）手势全删；
 *   · 左右侧条：长按/拖动 = 移动，轻点 = 停靠到该侧并变小窗；
 *   · 底边条：双击 = 关闭浮窗；
 *   · 贴边时手柄自动改挂到窗内侧，避免 5pt 缝隙下抓不到。 */
__attribute__((used)) static const char AevonSthenoGestureV43Marker[] = "AevonSthenoGestureV43";

/* V0.0.44 CI 标记（AevonSthenoGestureV44）：
 * AevonSthenoGestureV44 = 侧条拖动移动 / 轻点停靠或还原 + 底边条加宽（拖动移动、双击关闭）；
 * AevonLiveResizeV44    = 缩放改成每帧改 frame（不再 transform），圆角全程保留、画面实时；
 * AevonDockRestoreV44   = 轻点已停靠小窗还原主悬浮窗；
 * AevonDockAvoidV44     = 浮窗之间自动避让（小窗不再压住主窗手势条）；
 * AevonFloatEdgeGlowV44 = 四周 0.9pt 浅白描边（深色模式下能看清边界）；
 * AevonTopBlankCropV44  = 内容裁掉顶部状态栏空白（消除窗口顶部大片空白 / 竖长条）。 */
__attribute__((used)) static const char AevonSthenoGestureV44Marker[] = "AevonSthenoGestureV44";
__attribute__((used)) static const char AevonLiveResizeV44Marker[] = "AevonLiveResizeV44";
__attribute__((used)) static const char AevonDockRestoreV44Marker[] = "AevonDockRestoreV44";
__attribute__((used)) static const char AevonDockAvoidV44Marker[] = "AevonDockAvoidV44";
__attribute__((used)) static const char AevonFloatEdgeGlowV44Marker[] = "AevonFloatEdgeGlowV44";
__attribute__((used)) static const char AevonTopBlankCropV44Marker[] = "AevonTopBlankCropV44";

/* V0.0.45 CI 标记（AevonFloatSmoothV45）：
 * AevonFloatSmoothV45 = 缩放/拖动改 CADisplayLink 合帧 + 拖动期间圆角与避让不再逐帧重算
 *                       （治「画面一卡一卡」）；
 * AevonDockSizeV45    = 停靠小窗收到屏宽 30%（原 42%，不再被 minContentWidth 抬回去）；
 * AevonNoTopDockV45   = 顶部停靠彻底删除（Stheno 只有 leftPecent / rightPecent）；
 * AevonDockKeepSideV45= 停靠小窗只上下让位，不再被横向推离所在那一侧；
 * AevonEdgeThinV45    = 白描边 0.9pt/34% → 0.5pt/26%；
 * AevonCornerHotV45   = 下角块 36 → 48pt + 10pt 命中外扩（右下角缩放不好按）。 */
__attribute__((used)) static const char AevonFloatSmoothV45Marker[] = "AevonFloatSmoothV45";
__attribute__((used)) static const char AevonDockSizeV45Marker[] = "AevonDockSizeV45";
__attribute__((used)) static const char AevonNoTopDockV45Marker[] = "AevonNoTopDockV45";
__attribute__((used)) static const char AevonDockKeepSideV45Marker[] = "AevonDockKeepSideV45";
__attribute__((used)) static const char AevonEdgeThinV45Marker[] = "AevonEdgeThinV45";
__attribute__((used)) static const char AevonCornerHotV45Marker[] = "AevonCornerHotV45";

/* V0.0.46 CI 标记（AevonResizeSmoothV46）：
 * AevonResizeSmoothV46    = 缩放宽度改为「横/纵两向投影取平均」，治抖动变大变小
 *                           （旧实现 abs(dx)>=abs(dy) 二选一，两式结果差近一倍）；
 * AevonDockStackV46       = 停靠小窗竖向排版：中心优先、撞了下叠（第二个不再跑到上面）；
 * AevonFloatPaddingV46    = 内容上下各留 14pt 深色边，窗口圆角不再啃到导航栏返回按钮；
 * AevonTopCropV46         = 顶部裁剪量 = 状态栏空白 − 8pt，保证导航栏一行不缺；
 * AevonDockTapRestoreV46  = 停靠小窗整块窗身轻点即还原主悬浮窗；
 * AevonFrameMemoryCleanV46= 停靠态不写几何记忆 + 读到停靠档尺寸直接作废。 */
__attribute__((used)) static const char AevonResizeSmoothV46Marker[] = "AevonResizeSmoothV46";
__attribute__((used)) static const char AevonDockStackV46Marker[] = "AevonDockStackV46";
__attribute__((used)) static const char AevonFloatPaddingV46Marker[] = "AevonFloatPaddingV46";
__attribute__((used)) static const char AevonTopCropV46Marker[] = "AevonTopCropV46";
__attribute__((used)) static const char AevonDockTapRestoreV46Marker[] = "AevonDockTapRestoreV46";
__attribute__((used)) static const char AevonFrameMemoryCleanV46Marker[] = "AevonFrameMemoryCleanV46";

/* V0.0.47 CI 标记（Aevon(40) 的 4 条反馈）：
 * AevonNoBottomPadV47  = 移除底部深色边（任何页面都是死黑一条），顶部保留；
 * AevonRestorePosV47   = 还原主窗时位置与尺寸都回到停靠前，不再被贴边改写；
 * AevonDock916V47      = 停靠小窗改 9:16 并整体缩小（宽度 28%）；
 * AevonNoPushV47       = 跨窗自动避让整体停用，位置只由用户操作决定。 */
__attribute__((used)) static const char AevonNoBottomPadV47Marker[] = "AevonNoBottomPadV47";
__attribute__((used)) static const char AevonRestorePosV47Marker[] = "AevonRestorePosV47";
__attribute__((used)) static const char AevonDock916V47Marker[] = "AevonDock916V47";
__attribute__((used)) static const char AevonNoPushV47Marker[] = "AevonNoPushV47";

/* V0.0.48 CI 标记（Aevon(41) 的 5 条反馈）：
 * AevonGeomAnimV48     = 停靠/还原的几何动画（窗口与内容缩放同曲线，修「先黑屏再出画面」）；
 * AevonFloatAnimV48    = 开窗入场（上浮淡入）与关窗退场（缩放缓出）；
 * AevonFlushEdgeV48    = 贴边距离归零，停靠小窗真正贴住屏幕边缘；
 * AevonDockColumnV48   = 同侧小窗成列（第一个居中、后续向下）；
 * AevonGrowFromCenterV48 = 一列放不下时整列上移（第一个从中心往上走）；
 * AevonDockTapOnlyV48  = 已停靠时移除「轻点侧条还原」，只保留轻点窗身还原。 */
__attribute__((used)) static const char AevonGeomAnimV48Marker[] = "AevonGeomAnimV48";
__attribute__((used)) static const char AevonFloatAnimV48Marker[] = "AevonFloatAnimV48";
__attribute__((used)) static const char AevonFlushEdgeV48Marker[] = "AevonFlushEdgeV48";
__attribute__((used)) static const char AevonDockColumnV48Marker[] = "AevonDockColumnV48";
__attribute__((used)) static const char AevonGrowFromCenterV48Marker[] = "AevonGrowFromCenterV48";
__attribute__((used)) static const char AevonDockTapOnlyV48Marker[] = "AevonDockTapOnlyV48";

/* V0.0.49 CI 标记：
 * AevonFloatTouchBitV49 = 浮窗手势期写 notify state bit48（SpringBoard → Guard 跨进程握手）；
 * AevonDockColumnFillV49 = 还原小窗后停靠列回填（下方小窗上移补位）；
 * AevonFineMotionV49     = 统一弹簧动效参数（停靠 / 还原 / 开关窗 / 列重排）。 */
__attribute__((used)) static const char AevonFloatTouchBitV49Marker[] = "AevonFloatTouchBitV49";
__attribute__((used)) static const char AevonDockColumnFillV49Marker[] = "AevonDockColumnFillV49";
__attribute__((used)) static const char AevonFineMotionV49Marker[] = "AevonFineMotionV49";

/* V0.0.50 CI 标记（Aevon(43)：重写停靠列 + 阴影 bug）：
 * AevonDockTop5V50      = 停靠列重写：第一个贴右上角、顶边在屏高 10%，向下依次，最多 5 个；
 * AevonDockNoMoveV50    = 停靠小窗锁定，不可拖动 / 不可缩放，只能轻点还原；
 * AevonDockFillAnimV50  = 还原后下方整列上移补位（弹簧动画，不瞬移）；
 * AevonDockPassThroughV50 = 停靠小窗压在圆盘热区上时让位给热区（不再抢手指）；
 * AevonDockShadowV50    = 修「停靠时屏幕右边冒出黑色阴影」：动画期投影淡出 + 落位后重算 shadowPath。 */
__attribute__((used)) static const char AevonDockTop5V50Marker[] = "AevonDockTop5V50";
__attribute__((used)) static const char AevonDockNoMoveV50Marker[] = "AevonDockNoMoveV50";
__attribute__((used)) static const char AevonDockFillAnimV50Marker[] = "AevonDockFillAnimV50";
__attribute__((used)) static const char AevonDockPassThroughV50Marker[] = "AevonDockPassThroughV50";
__attribute__((used)) static const char AevonDockShadowV50Marker[] = "AevonDockShadowV50";

/* V0.0.51 CI 标记（Aevon(44) 的 4 条反馈）：
 * AevonDockNoTopBarV51 = 停靠小窗顶部留白归零（修「小窗顶部黑条」）；
 * AevonSingleMainV51   = 只允许一个主悬浮窗，旧主窗自动吸附成停靠小窗（修还原时堆叠）；
 * AevonIdleNoLockV51   = 有浮窗时压住系统空闲锁屏（看视频不再自动黑屏）；
 * AevonWindowShapeV51  = 主窗形态（整屏 ↔ 卡片），右下角轻点切换；默认卡片不再细长。 */
__attribute__((used)) static const char AevonDockNoTopBarV51Marker[] = "AevonDockNoTopBarV51";
__attribute__((used)) static const char AevonSingleMainV51Marker[] = "AevonSingleMainV51";
__attribute__((used)) static const char AevonIdleNoLockV51Marker[] = "AevonIdleNoLockV51";
__attribute__((used)) static const char AevonWindowShapeV51Marker[] = "AevonWindowShapeV51";

// V0.0.52：主窗只保留小胖屏一档 + 内容宽高双向完整适配 + 右下角只缩放
__attribute__((used)) static const char AevonFatWindowV52Marker[] = "AevonFatWindowV52";
__attribute__((used)) static const char AevonFitContentV52Marker[] = "AevonFitContentV52";
__attribute__((used)) static const char AevonNoShapeTapV52Marker[] = "AevonNoShapeTapV52";

// V0.0.53：主窗铺满裁切（无黑边）+ 停靠窗小胖屏 + 小窗接管吞摸 + 单主窗强制降级 + 停靠列按目标尺寸
__attribute__((used)) static const char AevonCoverCropV53Marker[] = "AevonCoverCropV53";
__attribute__((used)) static const char AevonDockFatV53Marker[] = "AevonDockFatV53";
__attribute__((used)) static const char AevonDockZoneTakeV53Marker[] = "AevonDockZoneTakeV53";
__attribute__((used)) static const char AevonDockKeepSideV53Marker[] = "AevonDockKeepSideV53";
__attribute__((used)) static const char AevonDockForceV53Marker[] = "AevonDockForceV53";
__attribute__((used)) static const char AevonDockSlotFitV53Marker[] = "AevonDockSlotFitV53";

/* V0.0.54：主窗回小胖屏 / 右下角不闪 / Guard 按停靠几何吞摸 /
 *          停靠列按进入顺序排 / 后台卡片隐藏 / 空闲计时器重置。 */
__attribute__((used)) static const char AevonFatMainV54Marker[] = "AevonFatMainV54";
__attribute__((used)) static const char AevonCornerNoFlashV54Marker[] = "AevonCornerNoFlashV54";
__attribute__((used)) static const char AevonGuardDockZoneV54Marker[] = "AevonGuardDockZoneV54";
__attribute__((used)) static const char AevonDockOrderV54Marker[] = "AevonDockOrderV54";
__attribute__((used)) static const char AevonSwitcherHideV54Marker[] = "AevonSwitcherHideV54";
__attribute__((used)) static const char AevonIdleResetV54Marker[] = "AevonIdleResetV54";

/* V0.0.55（读 Aevon(48) + AevonGuard(20)）
 *   AevonOverlayPolicyV55    浮窗只在桌面 / 全屏 App 显示（锁屏、控制中心、通知中心、切换器隐藏）
 *   AevonDockNoTouchV55      停靠小窗内容不接收触摸（从源头断掉转发进 App 的点击）
 *   AevonAdaptiveContentV55  真实改场景尺寸，让 App 按窗口大小重排（Stheno 同款）
 *   AevonIdleAssertV55       向系统申请空闲计时器禁用断言
 *   AevonLockBlockV55        直接拦下空闲触发的锁屏请求（侧键手动锁屏放行）
 *   AevonSceneFrameV55       场景 frame 读写垫片
 */
__attribute__((used)) static const char AevonOverlayPolicyV55Marker[] = "AevonOverlayPolicyV55";
__attribute__((used)) static const char AevonDockNoTouchV55Marker[] = "AevonDockNoTouchV55";
__attribute__((used)) static const char AevonAdaptiveContentV55Marker[] = "AevonAdaptiveContentV55";
__attribute__((used)) static const char AevonIdleAssertV55Marker[] = "AevonIdleAssertV55";
__attribute__((used)) static const char AevonLockBlockV55Marker[] = "AevonLockBlockV55";
__attribute__((used)) static const char AevonSceneFrameV55Marker[] = "AevonSceneFrameV55";

/* V0.0.57（读 Aevon(51) + AevonGuard(22)）
 *   AevonContentFitV57    内容改「整屏等比完整缩放」：不再裁切（修字变大 / 画面被剪 / 右侧工具栏消失）
 *   AevonNoSceneResizeV57 停用改场景 frame 与改 App keyWindow 两条路线（只裁视口 / 关窗残留黑屏）
 *   AevonOverlayAppV57    全屏 App 里浮窗常显（修「圆盘看不见但能操作、回桌面才出现」）
 *   AevonDockAtomicV57    还原时先把自身移出停靠列再降级其它主窗（停靠列一次成型，无断层）
 *   AevonDockSettleV57    停靠列落地校验（动画结束后按固定格对齐，消除残余缺口）
 *
 * 这些是**唯一可靠**的标记方式：Swift 侧的字符串常量会被 LLVM 优化掉（≤15 字节直接进寄存器），
 * 只有 ObjC 的 `__attribute__((used)) const char` 一定留在 __cstring 里。 */
__attribute__((used)) static const char AevonContentFitV57Marker[] = "AevonContentFitV57";
__attribute__((used)) static const char AevonNoSceneResizeV57Marker[] = "AevonNoSceneResizeV57";
__attribute__((used)) static const char AevonOverlayAppV57Marker[] = "AevonOverlayAppV57";
__attribute__((used)) static const char AevonDockAtomicV57Marker[] = "AevonDockAtomicV57";
__attribute__((used)) static const char AevonDockSettleV57Marker[] = "AevonDockSettleV57";

/* V0.0.58（PullOverMF 同款小胖屏，复刻自 com.qingc12.pullovermf 0.9.40 逆向）：
 *   AevonPomoCoverV58    小胖屏内容 = 整屏画面的一个「可视区」，铺满卡片、溢出裁掉
 *                        （PullOverMF: mfCardVisualScreenRect / mfMainCardScale）
 *   AevonCardVisPanV58   可视区位置可调（PullOverMF: mfUserVisualCenterX/Y，
 *                        设置驱动存偏好，0=贴顶 100=贴底）
 *   AevonPomoDefaultV58  「完整显示内容」默认关 —— 默认形态回到 0.60 小胖屏 */
__attribute__((used)) static const char AevonPomoCoverV58Marker[] = "AevonPomoCoverV58";
__attribute__((used)) static const char AevonCardVisPanV58Marker[] = "AevonCardVisPanV58";
__attribute__((used)) static const char AevonPomoDefaultV58Marker[] = "AevonPomoDefaultV58";

/* V0.0.59（真 resize + 关窗休眠修复）：
 *   AevonTrueResizeV59     真 resize 开跑（TrollOpen/Mango 路线）：场景 settings
 *                          帧 + displayConfiguration + setResizesHostedContext:
 *                          三路杠杆一起下发，App 按小窗尺寸真重排
 *   AevonReflowCheckV59    探测自证：App 画布变成目标尺寸才确认，5 秒未确认
 *                          自动回退整屏等比缩放（最坏 = V58 形态）
 *   AevonFrontmostCloseV59 关窗休眠修复：浮窗 App 即当前全屏前台 App 时跳过
 *                          sleep()（修「关掉浮窗后屏幕无法滑动」）
 *   AevonNoPanSliderV59    小胖屏可视区滑杆移除（真重排后无溢出可调） */
__attribute__((used)) static const char AevonTrueResizeV59Marker[] = "AevonTrueResizeV59";
__attribute__((used)) static const char AevonReflowCheckV59Marker[] = "AevonReflowCheckV59";
__attribute__((used)) static const char AevonFrontmostCloseV59Marker[] = "AevonFrontmostCloseV59";
__attribute__((used)) static const char AevonNoPanSliderV59Marker[] = "AevonNoPanSliderV59";

/* V0.0.60（真 resize 假阳性修复）：
 *   AevonReflowGateV60  探测硬闸门：displayConfiguration 写不进 settings 就整单
 *                       放弃（不写 frame 不推 diff，场景保持整屏），自动回退
 *                       V58 整屏等比缩放 —— 修「内容放大 + 显示不全」
 *                       （V59 探测假阳性 + 只推 frame 的组合症状）。 */
__attribute__((used)) static const char AevonReflowGateV60Marker[] = "AevonReflowGateV60";

/* V0.0.61（小胖屏主修 + 关窗呈现恢复 + 扩展排除）：
 *   AevonReflowIvarV61     displayConfiguration ivar 内存直写（FBSDisplayConfiguration
 *                          无任何 setter 选择子，ivar 是最后一层写入口）+ 全量诊断
 *                          （ivar 清单 / size 相关方法清单落日志）；
 *   AevonFrontmostRepreV61 关「前台 App 自己」的浮窗后强制前台回弹，逼系统重新
 *                          呈现全屏（presenter 销毁后状态不翻转 = 触摸路由断）。 */
__attribute__((used)) static const char AevonReflowIvarV61Marker[] = "AevonReflowIvarV61";
__attribute__((used)) static const char AevonFrontmostIDV62Marker[] = "AevonFrontmostIDV62";
__attribute__((used)) static const char AevonPolicyTryV62Marker[] = "AevonPolicyTryV62";
__attribute__((used)) static const char AevonIvarSafeV63Marker[] = "AevonIvarSafeV63";
__attribute__((used)) static const char AevonReflowAppGateV64Marker[] = "AevonReflowAppGateV64";
__attribute__((used)) static const char AevonTrueResizeWritesOffV65Marker[] = "AevonTrueResizeWritesOffV65";
__attribute__((used)) static const char AevonFrontmostRepreV61Marker[] = "AevonFrontmostRepreV61";
__attribute__((used)) static const char AevonSceneProbeP0Marker[] = "AevonSceneProbeP0";
__attribute__((used)) static const char AevonSceneDriverP1Marker[] = "AevonSceneDriverP1";
__attribute__((used)) static const char AevonGuardPrefsAliveV68Marker[] = "AevonGuardPrefsAliveV68";
__attribute__((used)) static const char AevonRestoreGraceV67Marker[] = "AevonRestoreGraceV67";
__attribute__((used)) static const char AevonRestoreGraceAllV70Marker[] = "AevonRestoreGraceAllV70";
/// CI 标记（V0.0.71）：P1 第 4/5 步修复（多 init 候选 + ScreenCore 正路）
__attribute__((used)) static const char AevonSceneP1V71Marker[] = "AevonSceneP1V71";
/// CI 标记（V0.0.72）：P1 provider=SBMainWorkspace 本体 + displayIdentity 走 dc._identity
__attribute__((used)) static const char AevonSceneP1V72Marker[] = "AevonSceneP1V72";
/// CI 标记（V0.0.73）：P1 provider 协议方法解析（代理转调下划线变体 + 全类扫描留证）
__attribute__((used)) static const char AevonSceneP1V73Marker[] = "AevonSceneP1V73";
/// CI 标记（V0.0.74）：浮窗按下时间戳通道（com.aevon.guardtap）——与坐标无关的穿透兜底
__attribute__((used)) static const char AevonNotifyStampV74Marker[] = "AevonNotifyStampV74";

/* V0.0.39 CI 标记：
 * AevonBootShieldV39    = 启动关键路径 ObjC 异常保护（入口创建 @try 兜底，防自动注销）；
 * AevonCrashTraceV39    = 崩溃捕获器升级：SIGSEGV 等致命信号落盘调用栈回溯；
 * AevonRingNoHoldRemoveV39 = 圆盘长按移除图标功能已删除。 */
__attribute__((used)) static const char AevonBootShieldV39Marker[] = "AevonBootShieldV39";
__attribute__((used)) static const char AevonCrashTraceV39Marker[] = "AevonCrashTraceV39";
__attribute__((used)) static const char AevonRingNoHoldRemoveV39Marker[] = "AevonRingNoHoldRemoveV39";

/* ──────────────────────────────────────────────────────────────────
 * V0.0.32：notify(3) 状态通道
 * 沙盒 App（抖音 / QQ）里 CFPreferences 被重定向进自身容器、guard.conf 也可能
 * 因目录权限写不进去（Aevon(25) 日志：guard.conf 写入失败 × N）。notify_set_state
 * 的 64 位状态挂在 notify token 上，跨进程且不受沙盒文件限制，是 Guard 的主配置源。
 * 打包：x:10 y:10 w:8 h:10 enabled:1 ring:1(bit39) 版本:8（0x34 = V34）
 *
 * V0.0.34（AevonNotifyRingBitV34）：bit39 = 圆盘展开状态。
 * 旧的 Darwin 广播（com.aevon.ringopen / ringclose）是 fire-and-forget，
 * 沙盒 App 里可能收不到或收得晚（Aevon(27)：连续 3 版「圆盘滑动带动全屏 App」）。
 * 改成共享内存状态位：SpringBoard 写、Guard 每条 sendEvent 直接读，零时序依赖。
 *
 * 注意：notify_set_state / notify_get_state 的参数是 **int token**，不是名字！
 * 必须先 notify_register_check("com.aevon.guardzone", &token) 再用 token 读写。
 * ────────────────────────────────────────────────────────────────── */
#include <notify.h>
#include <math.h>

static int AevonNotifyZoneToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.guardzone", &token);
    });
    return token;
}

#define AEVON_NOTIFY_VER (0x36ULL << 40)
#define AEVON_NOTIFY_RING_BIT (1ULL << 39)
/* V0.0.49（AevonFloatTouchBitV49）：浮窗手势期状态位。
 * 位 0~47 已被 zone(0~37) / enabled(38) / ring(39) / 版本(40~47) 占满，
 * 所以浮窗位放到 48 —— 版本号同时升到 0x35，老 Guard 读到 0x35 也能解析 zone。 */
#define AEVON_NOTIFY_FLOAT_BIT (1ULL << 48)
/* V0.0.54（AevonGuardDockZoneV54）：停靠列状态位。
 *
 * Aevon(47) 第 5 条：「快速点击停靠的小窗轮换时，依旧会触发应用内的点击」。
 * bit48 是「按下时写、抬手时清」的实时位，跟 backboardd 直投 App 的那一份存在**时序竞态** ——
 * 两个进程各自 sendEvent，谁先到不确定；快速连点时抬手刚清完、下一指又压下，Guard 读到 0 就放行。
 * 停靠列几何是**确定的**（顶部 10% 起点、固定 5 格、尺寸由屏宽反算），
 * 所以改成把「每侧有几个停靠小窗」写进状态位，Guard 自己算出每个槽位矩形，
 * 命中就吞 —— 与触摸时序完全无关，提前几秒就准备好了。
 * bit50~52 = 右侧数量(0~5)，bit53~55 = 左侧数量(0~5)。 */
#define AEVON_NOTIFY_DOCK_R_SHIFT 50
#define AEVON_NOTIFY_DOCK_L_SHIFT 53
#define AEVON_NOTIFY_DOCK_MASK 0x7ULL

/// 版本兼容：0x34（V46 及更早）、0x35（V49~V53）、0x36（本版，多停靠列状态）都算有效状态；
/// 只认最新版会让「旧 Guard + 新 SB」或反过来的机器上 zone 通道整条失效。
static inline BOOL AevonNotifyPackValid(uint64_t pack) {
    uint64_t ver = (pack >> 40) & 0xFFULL;
    return (ver == 0x34ULL || ver == 0x35ULL || ver == 0x36ULL);
}

void AevonNotifySetZone(double x, double y, double w, double h, int enabled) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return; }
        /* 读-改-写：保留 bit39 圆盘状态位（圆盘开着时设置页改几何，不能把 ring 位冲掉），
         * bit48 浮窗触摸位，以及 bit50~55 停靠列数量位（设置页刷新配置时浮窗可能正被操作）。 */
        uint64_t old = 0;
        notify_get_state(token, &old);
        uint64_t keep = 0;
        if (AevonNotifyPackValid(old)) {
            keep = old & (AEVON_NOTIFY_RING_BIT | AEVON_NOTIFY_FLOAT_BIT
                          | (AEVON_NOTIFY_DOCK_MASK << AEVON_NOTIFY_DOCK_R_SHIFT)
                          | (AEVON_NOTIFY_DOCK_MASK << AEVON_NOTIFY_DOCK_L_SHIFT));
        }
        uint64_t pack = keep;
        pack |= ((uint64_t)llround(x)) & 0x3FFULL;
        pack |= (((uint64_t)llround(y)) & 0x3FFULL) << 10;
        pack |= (((uint64_t)llround(w)) & 0xFFULL) << 20;
        pack |= (((uint64_t)llround(h)) & 0x3FFULL) << 28;
        pack |= (enabled ? 1ULL : 0ULL) << 38;
        pack |= AEVON_NOTIFY_VER;
        notify_set_state(token, pack);
        notify_post("com.aevon.guardzone");
    } @catch (NSException *exception) {
    }
}

/* V0.0.34：圆盘展开状态位（AevonNotifyRingBitV34）。
 * SpringBoard 在 presentRing / ringDidDismiss 调用；Guard 每条 sendEvent 直接读。 */
void AevonNotifySetRing(int on) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (!AevonNotifyPackValid(pack)) { pack = 0; }
        if (on) { pack |= AEVON_NOTIFY_RING_BIT; } else { pack &= ~AEVON_NOTIFY_RING_BIT; }
        pack |= AEVON_NOTIFY_VER;
        notify_set_state(token, pack);
        notify_post("com.aevon.guardzone");
    } @catch (NSException *exception) {
    }
}

/* V0.0.49（AevonFloatTouchBitV49）：浮窗手势期状态位。
 * 浮窗一按下置位、抬手 / 取消 / 超时清理时清零 —— Guard 据此在 App 进程内
 * 吞掉同一段时间的事件，堵住「backboardd 直投 App 那一份」的漏洞。 */
void AevonNotifySetFloatTouch(int on) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (!AevonNotifyPackValid(pack)) { pack = 0; }
        if (on) { pack |= AEVON_NOTIFY_FLOAT_BIT; } else { pack &= ~AEVON_NOTIFY_FLOAT_BIT; }
        pack |= AEVON_NOTIFY_VER;
        notify_set_state(token, pack);
        notify_post("com.aevon.guardzone");
    } @catch (NSException *exception) {
    }
}

/* V0.0.74（AevonGuardTapStampV74）：浮窗按下的**时间戳通道**（与坐标无关的最后一道防线）。
 *
 * Aevon(66) 日志暴露了坐标类 bug 的顽固性：App 进程 `locationInView:nil` 拿到的窗口坐标
 * 与 SpringBoard 记下的屏幕坐标对不上（同一轻点 SB 记 374,161，Guard 记 386,72），
 * 停靠槽位几何判据因此整条落空。V73 先用「窗口/屏幕双坐标系 + 纵向外扩」修，
 * 但坐标空间任何变动都会再次失配 —— 所以再加一条**完全不看坐标**的判据：
 * 浮窗一按下就写一个毫秒时间戳（CACurrentMediaTime，两进程同一时钟），
 * Guard 在 ended 时若发现「本次触摸抬手时，浮窗刚被按下不超过 350ms」，
 * 直接吞掉 ended（App 只剩 began，UIKit 不会合成点击）。
 *
 * 这条通道不依赖几何、不依赖 bit48 的读写先手，只依赖两台进程共享的系统时钟。 */
void AevonNotifyStampFloatTouch(void) {
    @try {
        static int token = -1;
        if (token < 0) { notify_register_check("com.aevon.guardtap", &token); }
        if (token < 0) { return; }
        uint64_t ms = (uint64_t)(CACurrentMediaTime() * 1000.0);
        notify_set_state(token, ms);
        notify_post("com.aevon.guardtap");
    } @catch (NSException *exception) {
    }
}

/* V0.0.54（AevonGuardDockZoneV54）：停靠列数量状态位。
 *
 * SpringBoard 每次停靠 / 还原 / 关窗后调用一次，把「左右两侧各有几个停靠小窗」写进共享内存。
 * Guard 读到数量后，用与 SB 完全一致的固定几何（顶部 10% 起点、每格 dockH+8、贴边）自己算出
 * 每个槽位矩形，命中就吞 —— 这条路径与触摸时序无关，可彻底堵住
 * 「快速点停靠小窗仍会点到 App」（Aevon(47) 第 5 条）。
 * 传 -1 表示「状态未知 / 不写」，0 表示该侧没有停靠窗。 */
void AevonNotifySetDockState(int rightCount, int leftCount) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (!AevonNotifyPackValid(pack)) { pack = 0; }
        uint64_t r = (rightCount < 0) ? ((pack >> AEVON_NOTIFY_DOCK_R_SHIFT) & AEVON_NOTIFY_DOCK_MASK)
            : (uint64_t)(rightCount & 7);
        uint64_t l = (leftCount < 0) ? ((pack >> AEVON_NOTIFY_DOCK_L_SHIFT) & AEVON_NOTIFY_DOCK_MASK)
            : (uint64_t)(leftCount & 7);
        pack &= ~((AEVON_NOTIFY_DOCK_MASK << AEVON_NOTIFY_DOCK_R_SHIFT)
                  | (AEVON_NOTIFY_DOCK_MASK << AEVON_NOTIFY_DOCK_L_SHIFT));
        pack |= (r << AEVON_NOTIFY_DOCK_R_SHIFT);
        pack |= (l << AEVON_NOTIFY_DOCK_L_SHIFT);
        pack |= AEVON_NOTIFY_VER;
        notify_set_state(token, pack);
        notify_post("com.aevon.guardzone");
    } @catch (NSException *exception) {
    }
}

/* ──────────────────────────────────────────────────────────────────
 * V0.0.56（AevonGuardFloatRectV56）：主悬浮窗矩形通道（独立 token）
 *
 * Aevon(50) 第 2 / 第 5 条：在全屏 App 里双击浮窗底边关闭、或快速连点停靠小窗
 * 切换主窗时，App 仍然会收到一次点击。
 *
 * 根因（日志 Aevon(50) 第 390 行 `入口窗口收到触摸 (x=205,y=698，宽容区内=否)` 佐证）：
 * backboardd 会把同一根手指**同时**投给 SpringBoard 与前台 App 两个进程。
 * SB 侧那份被浮窗吃掉了，App 那份只能靠 Guard 在 sendEvent 里丢 ——
 * 而 Guard 只有两条判据：bit48（按下写、抬手清，有竞态）和停靠格几何。
 * 主窗（非停靠态）本体压根没有几何判据，双击的第二下（间隔 0.36s > 350ms 放行）
 * 就落在"已放行"的窗口里，App 于是合成一次点击。
 *
 * 这里直接把「主窗矩形（含外侧手势区）」写进共享内存：只要手指落在浮窗盖住的
 * 那块屏幕上，App 一份就一律吞掉 —— 与触摸时序完全无关，双击 / 连点都不会漏。
 * 打包：x:10 y:10 w:10 h:10 valid:1(bit40) 版本:8(bit48~55)
 * （这两个通道用独立 token，版本位放在 48 就不会跟 guardzone 的布局打架）
 * ────────────────────────────────────────────────────────────────── */
#define AEVON_WIN_VER (0x36ULL << 48)

static int AevonNotifyFloatRectToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.guardfloat", &token);
    });
    return token;
}

/// rect 传 CGRectZero 表示「当前没有主悬浮窗」→ Guard 不再按矩形吞摸。
void AevonNotifySetFloatRect(double x, double y, double w, double h) {
    @try {
        int token = AevonNotifyFloatRectToken();
        if (token < 0) { return; }
        uint64_t pack = 0;
        if (w >= 1.0 && h >= 1.0) {
            pack |= ((uint64_t)llround(x) & 0x3FFULL);
            pack |= (((uint64_t)llround(y)) & 0x3FFULL) << 10;
            pack |= (((uint64_t)llround(w)) & 0x3FFULL) << 20;
            pack |= (((uint64_t)llround(h)) & 0x3FFULL) << 30;
            pack |= (1ULL << 40);
        }
        pack |= AEVON_WIN_VER;
        uint64_t old = 0;
        notify_get_state(token, &old);
        if (old == pack) { return; }   // 幂等：几何没变就不做跨进程写
        notify_set_state(token, pack);
        notify_post("com.aevon.guardfloat");
    } @catch (NSException *exception) {
    }
}

/* V0.0.56（AevonAdaptiveWindowV56）：App 窗口目标尺寸通道。
 *
 * Aevon(50) 第 4 条：改成场景尺寸后「字体变大、画面被剪裁、抖音右侧工具栏依旧不显示」。
 * 说明 `FBSMutableSceneSettings.setFrame:` 只改了**渲染视口**（scene layer 被裁到 267x458），
 * App 自己的 UIWindow 仍是整屏 430x932 —— 于是内容按 430 排版、视口只露出左边 62%，
 * 右边框（抖音右侧工具栏）被切掉，字看起来也就"变大"了。
 *
 * 真正的 Stheno 效果需要 App 端窗口一起变小。Guard 就注入在 App 进程里（UIKit），
 * 所以这里把目标尺寸写进共享内存，由 Guard 直接改 keyWindow.frame，App 随之重排。
 * 打包：w:10 h:10 valid:1(bit20) 版本:8(bit48~55)；w/h 传 0 = 恢复整屏。
 * ────────────────────────────────────────────────────────────────── */
static int AevonNotifyWindowSizeToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.guardwinsize", &token);
    });
    return token;
}

void AevonNotifySetWindowSize(double w, double h) {
    @try {
        int token = AevonNotifyWindowSizeToken();
        if (token < 0) { return; }
        uint64_t pack = 0;
        if (w >= 40.0 && h >= 40.0) {
            pack |= ((uint64_t)llround(w) & 0x3FFULL);
            pack |= (((uint64_t)llround(h)) & 0x3FFULL) << 10;
            pack |= (1ULL << 20);
        }
        pack |= AEVON_WIN_VER;
        uint64_t old = 0;
        notify_get_state(token, &old);
        if (old == pack) { return; }
        notify_set_state(token, pack);
        notify_post("com.aevon.guardwinsize");
    } @catch (NSException *exception) {
    }
}

int AevonNotifyGetZone(double *x, double *y, double *w, double *h, int *enabled) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return 0; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (!AevonNotifyPackValid(pack)) { return 0; }
        if (x) { *x = (double)(pack & 0x3FFULL); }
        if (y) { *y = (double)((pack >> 10) & 0x3FFULL); }
        if (w) { *w = (double)((pack >> 20) & 0xFFULL); }
        if (h) { *h = (double)((pack >> 28) & 0x3FFULL); }
        if (enabled) { *enabled = (int)((pack >> 38) & 1ULL); }
        return 1;
    } @catch (NSException *exception) {
        return 0;
    }
}

void AevonPrefSetBool(NSString *key, BOOL value) {
    @try {
        CFPreferencesSetAppValue((CFStringRef)key,
                                 value ? kCFBooleanTrue : kCFBooleanFalse,
                                 AevonPrefsAppID());
        CFPreferencesAppSynchronize(AevonPrefsAppID());
    } @catch (NSException *exception) {
        // 偏好写入失败不影响主流程
    }
}

void AevonPrefSetDouble(NSString *key, double value) {
    @try {
        CFPreferencesSetAppValue((CFStringRef)key,
                                 (__bridge CFPropertyListRef)[NSNumber numberWithDouble:value],
                                 AevonPrefsAppID());
        CFPreferencesAppSynchronize(AevonPrefsAppID());
    } @catch (NSException *exception) {
        // 偏好写入失败不影响主流程
    }
}

void AevonPrefSetInt(NSString *key, NSInteger value) {
    @try {
        CFPreferencesSetAppValue((CFStringRef)key,
                                 (__bridge CFPropertyListRef)[NSNumber numberWithInteger:value],
                                 AevonPrefsAppID());
        CFPreferencesAppSynchronize(AevonPrefsAppID());
    } @catch (NSException *exception) {
        // 偏好写入失败不影响主流程
    }
}

static NSMutableDictionary *_assertionsByPID = nil;

/*
 * 私有框架 API 的编译期声明（仅让编译器接受选择子，运行时由真实类实现）。
 * RBSAssertion / RBSTarget / RBSLegacyAttribute 均为私有框架类，无公开头文件，
 * 全部经 NSClassFromString 动态获取；这些声明挂在 NSObject 上只是为了通过类型检查。
 */
@interface NSObject (AevonRBSPrivate)
+ (id)targetWithPid:(int)pid;
+ (id)attributeWithReason:(NSInteger)reason flags:(NSUInteger)flags;
- (id)initWithExplanation:(NSString *)explanation target:(id)target attributes:(NSArray *)attributes;
- (BOOL)acquireWithError:(NSError **)error;
@end

@interface AevonAssertionShim : NSObject
/// 为指定 pid 获取保活断言（阻止内核挂起 / 降频），并尝试 task_resume / SIGCONT。
+ (void)acquireKeepAliveForPID:(int)pid;
/// 释放指定 pid 的保活断言。
+ (void)releaseKeepAliveForPID:(int)pid;
/// 仅恢复进程执行（不取断言）：suspended 拉起的 App 必须恢复才会渲染画面。
+ (void)resumePID:(int)pid;
@end

@implementation AevonAssertionShim

+ (void)initialize {
    if (self == [AevonAssertionShim class]) {
        _assertionsByPID = [NSMutableDictionary dictionary];
    }
}

+ (void)resumePID:(int)pid {
    if (pid <= 0) return;
    @try {
        mach_port_t task = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
        if (kr == KERN_SUCCESS && task != MACH_PORT_NULL) {
            task_resume(task);
            mach_port_deallocate(mach_task_self(), task);
        } else {
            kill(pid, SIGCONT);
        }
    } @catch (NSException *exception) {
        // 恢复失败不影响主流程
    }
}

+ (void)acquireKeepAliveForPID:(int)pid {
    @try {
        if (pid <= 0) return;

        @synchronized (self) {
            if (_assertionsByPID[@(pid)] != nil) return;
        }

        Class targetClass = NSClassFromString(@"RBSTarget");
        Class attributeClass = NSClassFromString(@"RBSLegacyAttribute");
        Class assertionClass = NSClassFromString(@"RBSAssertion");
        if (!targetClass || !attributeClass || !assertionClass) return;

        id target = [targetClass targetWithPid:pid];
        if (!target) return;

        // BKSProcessAssertionPreventTaskSuspend | PreventTaskThrottleDown
        // | WantsForegroundResourcePriority | PreventThrottleDownUI
        NSUInteger flags = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5);
        id attribute = [attributeClass attributeWithReason:7 flags:flags]; // BKSProcessAssertionReasonBackgroundUI
        if (!attribute) return;

        id assertion = [[assertionClass alloc] initWithExplanation:@"Aevon keep-alive"
                                                            target:target
                                                        attributes:@[attribute]];
        if (!assertion) return;

        NSError *error = nil;
        if (![assertion acquireWithError:&error]) {
            // 必须 invalidate 后再释放：否则 autorelease pool 回收时 dealloc 会抛
            // NSInternalInconsistencyException: Must be invalidated before deallocating
            if ([assertion respondsToSelector:@selector(invalidate)]) {
                [assertion invalidate];
            }
            return;
        }

        @synchronized (self) {
            _assertionsByPID[@(pid)] = assertion;
        }

        // 进程可能已被内核挂起：立即恢复执行
        [self resumePID:pid];
    } @catch (NSException *exception) {
        // 保活是尽力而为：任何失败静默忽略
    }
}

+ (void)releaseKeepAliveForPID:(int)pid {
    @try {
        if (pid <= 0) return;
        @synchronized (self) {
            id assertion = _assertionsByPID[@(pid)];
            if (assertion) {
                if ([assertion respondsToSelector:@selector(invalidate)]) {
                    [assertion invalidate];
                }
                [_assertionsByPID removeObjectForKey:@(pid)];
            }
        }
    } @catch (NSException *exception) {
        // 忽略
    }
}

@end

/*
 * App 图标垫片（V0.0.22 多源重写）。
 *
 * 为什么要多源：V0.0.21 只走 `SBIconController -applicationIconImageForBundleIdentifier:format:scale:`
 * 一条路，在 iOS 17.3.1 的 SpringBoard 里实测恒返回 nil（旧版本只能退回首字母色点，
 * 用户看到的就是「圆盘和面板里都没有 App 图标」）。这里改成四级取图，任一成功即返回：
 *   ① SBIconModel → 图标对象 → `-iconImageWithInfo:`（iOS 13+ 屏幕快照渲染，最准）
 *   ② App 包内的 PNG（AppIcon60x60@3x.png 等，系统 App 和多数第三方 App 都有）
 *   ③ UIImage 私有 `+_applicationIconImageForBundleIdentifier:format:scale:`
 *   ④ SBIconController 的旧接口（format 0~3 逐个试）
 * 全部失败返回 nil，Swift 侧仍保留文字卡片兜底。
 *
 * 私有调用一律 @try/@catch：图标取不到是小事，绝不能让它把 SpringBoard 拖下水。
 */

typedef struct {
    CGSize size;
    CGFloat scale;
    CGFloat cornerRadius;
} AevonIconImageInfo;

static NSMutableDictionary<NSString *, UIImage *> *AevonIconCache(void) {
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

/* ① 桌面图标模型 → iconImageWithInfo: */
static UIImage *AevonIconFromIconModel(NSString *bundleID, CGFloat pointSize) {
    Class ctlClass = NSClassFromString(@"SBIconController");
    if (ctlClass == Nil) { return nil; }
    id controller = ((id (*)(id, SEL))objc_msgSend)(ctlClass, NSSelectorFromString(@"sharedInstance"));
    if (controller == nil || ![controller respondsToSelector:NSSelectorFromString(@"model")]) { return nil; }
    id model = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"model"));
    if (model == nil) { return nil; }

    id icon = nil;
    SEL leafSelector = NSSelectorFromString(@"leafIconForIdentifier:");
    if ([model respondsToSelector:leafSelector]) {
        icon = ((id (*)(id, SEL, id))objc_msgSend)(model, leafSelector, bundleID);
    }
    if (icon == nil) {
        SEL appSelector = NSSelectorFromString(@"applicationIconForBundleIdentifier:");
        if ([model respondsToSelector:appSelector]) {
            icon = ((id (*)(id, SEL, id))objc_msgSend)(model, appSelector, bundleID);
        }
    }
    if (icon == nil) { return nil; }

    SEL infoSelector = NSSelectorFromString(@"iconImageWithInfo:");
    if ([icon respondsToSelector:infoSelector]) {
        NSMethodSignature *signature = [icon methodSignatureForSelector:infoSelector];
        if (signature != nil && signature.numberOfArguments >= 3) {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setTarget:icon];
            [invocation setSelector:infoSelector];
            AevonIconImageInfo info;
            info.size = CGSizeMake(pointSize, pointSize);
            info.scale = 3.0;
            info.cornerRadius = pointSize * 0.2237;
            [invocation setArgument:&info atIndex:2];
            [invocation retainArguments];
            [invocation invoke];
            __unsafe_unretained id result = nil;
            [invocation getReturnValue:&result];
            if ([result isKindOfClass:[UIImage class]]) { return (UIImage *)result; }
        }
    }
    SEL legacySelector = NSSelectorFromString(@"getIconImage:");
    if ([icon respondsToSelector:legacySelector]) {
        id image = ((id (*)(id, SEL, id))objc_msgSend)(icon, legacySelector, bundleID);
        if ([image isKindOfClass:[UIImage class]]) { return (UIImage *)image; }
    }
    return nil;
}

/* ② App 包内 PNG（不依赖私有 UI 接口，系统 App 必有） */
static UIImage *AevonIconFromBundleFiles(NSString *bundleID) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass == Nil) { return nil; }
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyClass respondsToSelector:proxySelector]) { return nil; }
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, bundleID);
    if (proxy == nil) { return nil; }

    NSURL *bundleURL = nil;
    @try {
        if ([proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) {
            bundleURL = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleURL"));
        }
    } @catch (NSException *exception) {
        bundleURL = nil;
    }
    if (![bundleURL isKindOfClass:[NSURL class]]) { return nil; }
    NSString *directory = bundleURL.path;
    if (directory.length == 0) { return nil; }

    NSArray<NSString *> *preferred = @[
        @"AppIcon60x60@3x.png",
        @"AppIcon60x60@2x.png",
        @"AppIcon76x76@2x~ipad.png",
        @"Icon-60@3x.png",
        @"Icon-60@2x.png",
        @"Icon@3x.png",
        @"Icon@2x.png",
        @"Icon.png",
        @"icon.png",
    ];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in preferred) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![manager fileExistsAtPath:path]) { continue; }
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image != nil) { return image; }
    }

    // 兜底：目录里所有 png 里挑名字像图标、像素最大的那张
    NSArray<NSString *> *files = [manager contentsOfDirectoryAtPath:directory error:NULL];
    UIImage *best = nil;
    CGFloat bestArea = 0;
    for (NSString *file in files) {
        if (![[file lowercaseString] hasSuffix:@".png"]) { continue; }
        NSString *lower = [file lowercaseString];
        if (!([lower containsString:@"appicon"] || [lower containsString:@"icon"])) { continue; }
        if ([lower containsString:@"mask"] || [lower containsString:@"small"] ||
            [lower containsString:@"spotlight"] || [lower containsString:@"notification"]) { continue; }
        NSString *path = [directory stringByAppendingPathComponent:file];
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image == nil) { continue; }
        CGFloat area = image.size.width * image.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = image;
        }
    }
    return best;
}

/* ③ UIImage 的私有接口：+_applicationIconImageForBundleIdentifier:format:scale: */
static UIImage *AevonIconFromUIImage(NSString *bundleID, CGFloat scale) {
    Class imageClass = [UIImage class];
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![imageClass respondsToSelector:selector]) { return nil; }
    CGFloat useScale = scale > 0 ? scale : 3.0;
    for (int format = 0; format <= 3; format++) {
        @try {
            id image = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(imageClass, selector, bundleID, format, useScale);
            if ([image isKindOfClass:[UIImage class]]) { return (UIImage *)image; }
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return nil;
}

/* ④ SBIconController 旧接口 */
static UIImage *AevonIconFromIconController(NSString *bundleID, CGFloat scale) {
    Class ctlClass = NSClassFromString(@"SBIconController");
    if (ctlClass == Nil) { return nil; }
    id controller = ((id (*)(id, SEL))objc_msgSend)(ctlClass, NSSelectorFromString(@"sharedInstance"));
    if (controller == nil) { return nil; }
    SEL selector = NSSelectorFromString(@"applicationIconImageForBundleIdentifier:format:scale:");
    if (![controller respondsToSelector:selector]) { return nil; }
    CGFloat useScale = scale > 0 ? scale : 3.0;
    for (int format = 0; format <= 3; format++) {
        @try {
            id image = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(controller, selector, bundleID, format, useScale);
            if ([image isKindOfClass:[UIImage class]]) { return (UIImage *)image; }
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return nil;
}

UIImage *AevonIconImage(NSString *bundleID, CGFloat scale) {
    if (bundleID.length == 0) { return nil; }
    NSMutableDictionary<NSString *, UIImage *> *cache = AevonIconCache();
    UIImage *cached = cache[bundleID];
    if (cached != nil) { return cached; }

    CGFloat pointSize = 60.0;
    UIImage *image = nil;
    @try {
        image = AevonIconFromIconModel(bundleID, pointSize);
        if (image == nil) { image = AevonIconFromBundleFiles(bundleID); }
        if (image == nil) { image = AevonIconFromUIImage(bundleID, scale); }
        if (image == nil) { image = AevonIconFromIconController(bundleID, scale); }
    } @catch (NSException *exception) {
        image = nil;
    }
    if (image != nil) { cache[bundleID] = image; }
    return image;
}

/*
 * dyld 构造函数入口（与垫片同文件，省掉单独的 ctor.m）。
 * 保持极小：只转发到 Swift 侧的分屏初始化函数，Swift 内部全部有守卫，
 * 任何失败只记录日志，绝不把异常抛回 dyld。
 */
extern void AevonInitialize(void);

__attribute__((constructor)) static void AevonConstructor(void) {
    AevonInitialize();
}

/* V0.0.39（AevonBootShieldV39）：ObjC 异常保护块。
 * 入口窗口创建等启动关键路径经此执行：UIKit 抛 NSException 时捕获带出，
 * SpringBoard 不再被带崩（V0.0.38 自动注销问题的兜底网）。 */
BOOL AevonTryExecute(void (^block)(void), NSString **outName, NSString **outReason) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outName != NULL) { *outName = exception.name; }
        if (outReason != NULL) { *outReason = exception.reason; }
        return NO;
    }
}

/* V0.0.39（AevonCrashTraceV39）：execinfo 转发（Swift Darwin 模块未暴露）。 */
#include <execinfo.h>

NSInteger AevonBacktrace(void **stack, int max) {
    return (NSInteger)backtrace(stack, max);
}

void AevonBacktraceSymbolsFD(void **stack, int size, int fd) {
    backtrace_symbols_fd(stack, size, fd);
}

/* V0.0.40（AevonCrashAttrV40）：崩溃归因。
 * 真机 Aevon(32) 定论：其他插件（ZZEvoCenterRuntime）崩溃也会被我们的信号
 * 处理器捕获，崩溃保护「看到 SB 崩了就禁用 Aevon」造成误伤——用户开启插件
 * 后每次注销都被自动关回去，永远开不起来。
 * 方案：加载时解析自身 mach-o 的 __TEXT 段范围；信号处理里对回溯帧做
 * 纯指针比较（无 malloc / 无符号化，async-signal-safe），只有崩溃栈里
 * 真的出现了 Aevon 自己的帧，才承认是 Aevon 的锅。 */
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <string.h>

static uintptr_t aevonTextStart = 0;
static uintptr_t aevonTextEnd = 0;

void AevonCrashAttrPrepare(void) {
    Dl_info info;
    if (dladdr((void *)AevonCrashAttrPrepare, &info) == 0 || info.dli_fbase == NULL) { return; }
    uintptr_t base = (uintptr_t)info.dli_fbase;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64) { return; }

    /* 优先用 getsectdata 取 __TEXT：包含头部与全部代码段 */
    unsigned long size = 0;
    uint8_t *start = getsectiondata(mh, "__TEXT", "__text", &size);
    if (start != NULL && size > 0) {
        aevonTextStart = (uintptr_t)start;
        aevonTextEnd = (uintptr_t)start + size;
        return;
    }
    /* 兜底：__text 段取不到就用整个镜像基址往后 64MB（宁可误判参与也不漏判） */
    aevonTextStart = base;
    aevonTextEnd = base + 0x4000000;
}

int AevonCrashAttrOwnsFrame(void **stack, int count, int skip) {
    if (aevonTextEnd == 0) { return 0; }
    for (int i = skip; i < count; i++) {
        uintptr_t pc = (uintptr_t)stack[i];
        if (pc >= aevonTextStart && pc < aevonTextEnd) { return 1; }
    }
    return 0;
}
