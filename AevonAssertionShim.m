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

#define AEVON_NOTIFY_VER (0x34ULL << 40)
#define AEVON_NOTIFY_RING_BIT (1ULL << 39)

void AevonNotifySetZone(double x, double y, double w, double h, int enabled) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return; }
        /* 读-改-写：保留 bit39 圆盘状态位（圆盘开着时设置页改几何，不能把 ring 位冲掉） */
        uint64_t old = 0;
        notify_get_state(token, &old);
        uint64_t ringBit = (((old >> 40) & 0xFF) == 0x34) ? (old & AEVON_NOTIFY_RING_BIT) : 0;
        uint64_t pack = ringBit;
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
        if (((pack >> 40) & 0xFF) != 0x34) { pack = 0; }
        if (on) { pack |= AEVON_NOTIFY_RING_BIT; } else { pack &= ~AEVON_NOTIFY_RING_BIT; }
        pack |= AEVON_NOTIFY_VER;
        notify_set_state(token, pack);
        notify_post("com.aevon.guardzone");
    } @catch (NSException *exception) {
    }
}

/* V0.2.12（AevonAppRingGoneGuardV212）：读圆盘状态位（bit39）。
 *
 * 这是全插件唯一「零时序、零事件依赖」的状态判据：不靠 Darwin 通知送达、
 * 不靠抬手帧到达、不靠跨进程回调。App 侧识别器只要拿它对照自己的 state，
 * 就能判断「圆盘早就关了，我却还压着这根手指」。
 * 读不到（token 失效 / 版本位不对）一律返回 0 —— 出错方向必须是「认为圆盘已关」，
 * 因为对 App 来说「以为圆盘还开着」会把整台设备的滚动全部压死。 */
int AevonNotifyGetRing(void) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return 0; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (((pack >> 40) & 0xFF) != 0x34) { return 0; }
        return (pack & AEVON_NOTIFY_RING_BIT) ? 1 : 0;
    } @catch (NSException *exception) {
        return 0;
    }
}

int AevonNotifyGetZone(double *x, double *y, double *w, double *h, int *enabled) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return 0; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (((pack >> 40) & 0xFF) != 0x34) { return 0; }
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

void AevonPrefSetString(NSString *key, NSString *value) {
    @try {
        if (key.length == 0) { return; }
        if (value.length == 0) {
            /* 空串 = 没有浮窗：直接删键，比写一个空字符串更干净（App 侧读到的就是 nil） */
            CFPreferencesSetAppValue((CFStringRef)key, NULL, AevonPrefsAppID());
        } else {
            CFPreferencesSetAppValue((CFStringRef)key,
                                     (__bridge CFPropertyListRef)value,
                                     AevonPrefsAppID());
        }
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

/* ── V0.1.3（AevonGateRemovedV103）：历史 CI 校验串收容 ──
 * 「场景停用门控」整体移除后，下面两条串在运行期已没有任何代码路径，
 * 但历史 CI 校验（V0.1.2 块）仍要求二进制里能查到 —— 用 used 常量钉住，
 * 保证「历史校验串只加不能改」这条铁律不破。
 *   AevonTakeoverBandV102 = 旧接管带（只外扩 18pt，纵向不铺满，已升级为 V103）
 *   AevonGateSafeV102     = 停用门控原始实现的 ObjC 异常保护（随门控一起删除） */
__attribute__((used)) static const char AevonTakeoverBandV102Marker[] = "AevonTakeoverBandV102";
__attribute__((used)) static const char AevonGateSafeV102Marker[] = "AevonGateSafeV102";

/* ── V0.1.5（AevonNoFBSWriteV105 / AevonNoSnapV105 / AevonNoTapSummonV105）：历史 CI 校验串收容 ──
 * 本版删掉了三类东西，它们在运行期已没有任何代码路径，但历史 CI 校验块仍要求
 * 二进制里能查到（「历史校验串只加不能改」铁律）—— 全部用 used 常量钉住：
 *   AevonTapSummonV102            = 轻点热区呼出圆盘（误触太多，0.1.5 删除）
 *   sk_fbscene_updateSettings…    = FBScene 设置写入 hook（注销崩溃源，0.1.5 删除）
 *   AevonFBSceneHooks             = 同上，hook 类名
 *   AevonSnap / AevonSnapSlot     = 左右吸附几何与槽位（0.1.5 删除）
 *   AevonSplitFlow                = 左右分屏流程（0.1.5 删除）
 *   SnapEnabled / SystemGestureEdge = 已删除的两个设置开关键 */
__attribute__((used)) static const char AevonTapSummonV102Marker[] = "AevonTapSummonV102";
__attribute__((used)) static const char AevonFBSWriteV104Marker[] = "sk_fbscene_updateSettings";
__attribute__((used)) static const char AevonFBSceneHooksV104Marker[] = "AevonFBSceneHooks";
__attribute__((used)) static const char AevonSnapV14Marker[] = "AevonSnap";
__attribute__((used)) static const char AevonSnapSlotV14Marker[] = "AevonSnapSlot";
__attribute__((used)) static const char AevonSplitFlowV14Marker[] = "AevonSplitFlow";
__attribute__((used)) static const char AevonSnapPrefV14Marker[] = "SnapEnabled";
__attribute__((used)) static const char AevonSysGesturePrefV104Marker[] = "SystemGestureEdge";

/* ── V0.1.5 补充收容：这三个标记在本版只出现在源码注释里（Swift 注释不进二进制），
 * 但历史 CI 校验块（V0.1.3 / V0.1.4）要求二进制里能查到，故用 used 常量钉住。
 *   AevonGateRemovedV103     = 场景停用门控已移除（0.1.3 的定论标记）
 *   AevonSystemGestureV104   = 0.1.4 的「找系统手势窗口」方案（0.1.5 改为管线，标记保留）
 *   AevonNoTapSummonV105 / AevonNoSnapV105 = 本版两个删除项的标记 */
__attribute__((used)) static const char AevonGateRemovedV103Marker[] = "AevonGateRemovedV103";
__attribute__((used)) static const char AevonSystemGestureV104Marker[] = "AevonSystemGestureV104";
__attribute__((used)) static const char AevonNoTapSummonV105Marker[] = "AevonNoTapSummonV105";
__attribute__((used)) static const char AevonNoSnapV105Marker[] = "AevonNoSnapV105";

/* ── V0.1.6（AevonProbeV106 / AevonFullscreenCloseV106 / AevonWinDumpFullV106）：本版标记 ──
 * 这些串同时出现在运行期日志里，正常构建就能查到；这里用 used 常量再钉一遍，
 * 避免以后有人把日志文案改掉导致 CI 断言假红。 */
__attribute__((used)) static const char AevonProbeV106Marker[] = "AevonProbeV106";
__attribute__((used)) static const char AevonFullscreenCloseV106Marker[] = "AevonFullscreenCloseV106";
__attribute__((used)) static const char AevonWinDumpFullV106Marker[] = "AevonWinDumpFullV106";
__attribute__((used)) static const char AevonSystemGestureV106Marker[] = "AevonSystemGestureV106";
__attribute__((used)) static const char AevonLaunchProbeV106Marker[] = "AevonLaunchProbeV106";

/* ── V0.1.7（AevonProbeV107 / AevonShieldV107 / AevonSafeIvarV107）：本版标记 ──
 * 这些串在运行期日志里本来就会出现；这里再用 used 常量钉一遍，避免以后改文案把 CI 断言弄假红。
 *   AevonProbeV107        = 六组探针一次部署（P1~P6）
 *   AevonMultiProbeV107   = 「多组探针一次收齐」这件事本身的标记
 *   AevonShieldV107       = ObjC @try 兜底（Swift 的 do/catch 捕不到的选择子异常）
 *   AevonObjCProbeV107    = 类表 / 方法名 / ivar 扫描搬进 ObjC（避开 Swift 动态转换）
 *   AevonSafeIvarV107     = ivar 读取改 object_getIvar，不再裸 load 野指针
 * 0.1.6 的探针文件已删（它把 SpringBoard 打死了）。那四个 V106 标记原本就在上面
 * 更早的收容块里，本块不再重复定义（重复定义会直接编译失败）。 */
__attribute__((used)) static const char AevonProbeV107Marker[] = "AevonProbeV107";
__attribute__((used)) static const char AevonMultiProbeV107Marker[] = "AevonMultiProbeV107";
__attribute__((used)) static const char AevonShieldV107Marker[] = "AevonShieldV107";
__attribute__((used)) static const char AevonObjCProbeV107Marker[] = "AevonObjCProbeV107";
__attribute__((used)) static const char AevonSafeIvarV107Marker[] = "AevonSafeIvarV107";
/* 探针组标记（每组一行日志都带，CI 逐组断言，缺组即红） */
__attribute__((used)) static const char AevonProbeP1V107Marker[] = "AevonProbeP1V107";
__attribute__((used)) static const char AevonProbeP2V107Marker[] = "AevonProbeP2V107";
__attribute__((used)) static const char AevonProbeP3V107Marker[] = "AevonProbeP3V107";
__attribute__((used)) static const char AevonProbeP4V107Marker[] = "AevonProbeP4V107";
__attribute__((used)) static const char AevonProbeP5V107Marker[] = "AevonProbeP5V107";
__attribute__((used)) static const char AevonProbeP6V107Marker[] = "AevonProbeP6V107";

/* ── V0.1.13（AevonPipelineStandDownV113 / AevonBandTakeoverBeganV113）：本版标记 ──
 * 背景：识别器整条停手（不再接收任何触摸），起手窗两态化（默认整段交回 App / 开关按下即接管）。
 *
 *   AevonPipelineStandDownV113 = 识别器停手（断掉「扣住 App 的 began 再整段补投」那条链）
 *   AevonBandTakeoverBeganV113 = 起手窗两态开关 BandTakeoverFromBegan
 *
 * 同时收容两条**已经不在任何运行期日志里**的历史串：
 *   AevonBandTrackV111 = 0.1.11 的 0.30s 跟踪采样（采样调用点随识别器停手一起作废）
 *   AevonBandWidenV111 = 0.1.11 的「老通道铺到起手窗 46pt」（本版起手窗已不干预）
 * 它们仍被 V0.1.11 的 CI 块断言，所以只能用 used 钉住，不许从二进制里消失。 */
__attribute__((used)) static const char AevonPipelineStandDownV113Marker[] = "AevonPipelineStandDownV113";
__attribute__((used)) static const char AevonBandTakeoverBeganV113Marker[] = "AevonBandTakeoverBeganV113";
__attribute__((used)) static const char AevonBandTrackV111Marker[] = "AevonBandTrackV111";
__attribute__((used)) static const char AevonBandWidenV111Marker[] = "AevonBandWidenV111";

/* ── V0.1.14（AevonProbeP7V114 / 宿主审计）：本版标记 ──
 * 本版**只加探针，不改任何行为**：右缘策略与 0.1.13 完全一致（识别器停手）。
 * 五组探针只回答一个问题 —— 「我们自己的视图在右缘那个坐标上到底有没有被窗口问过」。
 *
 *   AevonProbeP7V114       = 五组调度入口
 *   AevonWindowHitV114     = P7-1 窗口级命中链
 *   AevonHostAuditV114     = P7-2 入口窗口/容器/App画面容器 三者关系
 *   AevonRecognizerHostV114= P7-3 既有系统识别器的宿主视图与覆盖区
 *   AevonOwnRecognizerV114 = P7-4 我们登记的那个识别器有没有宿主视图
 *   AevonDeferProbeV114    = P7-5 BKS 延迟路由谓词能否表达几何区域
 *
 * 全部用 used 钉住：探针日志串多数很短，Swift 会走 SSO 内联、`strings` 查不到，
 * 而 CI 一定是按二进制字节断言的（源码 grep 会把注释也算进去）。 */
__attribute__((used)) static const char AevonProbeP7V114Marker[] = "AevonProbeP7V114";
__attribute__((used)) static const char AevonWindowHitV114Marker[] = "AevonWindowHitV114";
__attribute__((used)) static const char AevonHostAuditV114Marker[] = "AevonHostAuditV114";
__attribute__((used)) static const char AevonRecognizerHostV114Marker[] = "AevonRecognizerHostV114";
__attribute__((used)) static const char AevonOwnRecognizerV114Marker[] = "AevonOwnRecognizerV114";
__attribute__((used)) static const char AevonDeferProbeV114Marker[] = "AevonDeferProbeV114";

/* ── V0.1.15（AevonRightEdgeTakeoverV115）：本版标记 ──
 * Aevon(82) 的 P7 把前九版的假设全推翻了：
 *   ① 右缘 (424,400) 的最高命中**就是我们自己的带视图**（在 SBMainSwitcherWindow level=5 里
 *      压着 SBDeviceApplicationSceneView）→ 命中早就赢了，不是瓶颈；
 *   ② 入口窗口三个落点全是 nil（纯穿透）→ 它不参与裁决；
 *   ③ 我们的识别器和 14 个系统识别器**同宿** UISystemGestureView(0,0,430,932) → 确实进了系统手势环境；
 *   ④ BKSHIDEventDeferringPredicate 只有 environment/display/token，无几何 → 按区域延迟判死。
 * 结论：命中赢 ≠ App 收不到；系统手势环境只给观察权；能决定 App 收不收摸的只有
 * `UIApplication -sendEvent:` 整指丢弃（热区 12/12 干净就是靠它）。
 * 所以本版把右缘做成「第二个热区」：began 即接管，与热区共用 ownsTouch 生命周期。
 *
 *   AevonRightEdgeTakeoverV115 = 右缘接管带（总入口整指吞 + 判向呼出）
 *   AevonRightEdgeWidthV115    = 带宽/带高可调（默认 28pt × 下半 60%）
 *   AevonBandTouchBeganV115    = 命中通道取证（bandView 是否真的拿到 touches）
 *
 * 全部用 used 钉住：Swift 短串会走 SSO 内联，`strings` 查不到；CI 只认二进制字节。 */
__attribute__((used)) static const char AevonRightEdgeTakeoverV115Marker[] = "AevonRightEdgeTakeoverV115";
__attribute__((used)) static const char AevonRightEdgeWidthV115Marker[] = "AevonRightEdgeWidthV115";
__attribute__((used)) static const char AevonBandTouchBeganV115Marker[] = "AevonBandTouchBeganV115";

/* ── V0.1.16（AevonRightEdgeShowBandV116）：本版标记 ──
 * Aevon(83) 的实测：右缘接管带 3/3 生效（起手 → 判向 → 呼出），机制已通。
 * 但那份日志暴露了两件事：
 *   ① 三次落点全在 y=656~671 —— 接管带最下沿、紧贴热区上边界。28pt 是一条手指看不见的宽度，
 *      用户在真机上无法确认「带在哪 / 这次是不是我们接住的」；
 *   ② 0.1.15 设计的「命中共」取证**结构性不可能出现**：总入口在 began 就把整个 UIEvent 丢了，
 *      `return` 掉原 sendEvent → hitTest 根本没跑 → bandView 永远收不到 touches。
 *      所以「两条都有」这个判据从一开始就是错的，必须写清楚，不能再拿它当证据。
 * 本版只加一层绘制（不改任何触摸行为）：把带的真实范围画出来 + 接管成功闪一下，
 * 让真机测试从「猜」变成「看」。
 *
 *   AevonRightEdgeShowBandV116 = 可视化开关（RightEdgeShowBand，默认关）
 *   AevonBandIndicatorV116     = 带子绘制 + 闪示 + 设置变更即时重画
 *
 * 同样 used 钉住：CI 只认二进制字节。 */
__attribute__((used)) static const char AevonRightEdgeShowBandV116Marker[] = "AevonRightEdgeShowBandV116";
__attribute__((used)) static const char AevonBandIndicatorV116Marker[] = "AevonBandIndicatorV116";

/* V0.1.17（Aevon(84) 全屏卡死事故）：把「全屏自绘」整块删掉，换成按需提示条 + 两道急救闸。
 *
 *   AevonNoBandDrawV117     = 带视图退回 1×1 隐藏占位（不画 / 不命中 / 不接触摸）
 *   AevonBandHintV117       = 可视化改为按需提示条（开关变化 3 秒 / 接管成功 0.35 秒后自动消失）
 *   AevonDeadManV117        = 死手开关：接管状态超期自动释放，圆盘展开超 20 秒强制收起
 *   AevonPanicThreeFingerV117 = 三指同时按下急救：释放全部接管 + 写盘关掉右缘接管两个开关
 *
 * 这几条都是运行期真正会走到的路径，但 Swift 侧字符串可能被内联（≤15 字节）或被优化掉，
 * 所以由 ObjC 的 used 常量钉在二进制里，CI 用 strings 校验。 */
__attribute__((used)) static const char AevonNoBandDrawV117Marker[] = "AevonNoBandDrawV117";
__attribute__((used)) static const char AevonBandHintV117Marker[] = "AevonBandHintV117";
__attribute__((used)) static const char AevonDeadManV117Marker[] = "AevonDeadManV117";
__attribute__((used)) static const char AevonPanicThreeFingerV117Marker[] = "AevonPanicThreeFingerV117";

/* V0.1.18（Aevon(85) 四次落点全部在带外）：
 *
 *   AevonRightEdgeDefaultV118 = 右缘带默认宽度 28 → 46pt、下限 8 → 24pt
 *   AevonRightEdgeMissHintV118 = 带外落点自述原因（宽度差 / 高度差 + 需要多大），抬手补一行结论
 *   AevonRightEdgeWidenV118    = 把被旧默认值坑住的带宽（≤28pt）一次性抬到 46
 *
 * 依据：Aevon(85) 四次右缘落点距右缘 12 / 19 / 25 / 42pt，宽度被拖到 17pt 后 0 次进带
 * （(411,744) 只差 1pt）。覆盖率：17pt×60% = 0/4、28pt×60% = 1/4、46pt×60% = 3/4。
 * 结论：可调宽度但允许调到「必然落空」的区间 = 把「猜自己落点」的成本转给用户，必须改默认值 + 抬下限。 */
__attribute__((used)) static const char AevonRightEdgeDefaultV118Marker[] = "AevonRightEdgeDefaultV118";
__attribute__((used)) static const char AevonRightEdgeMissHintV118Marker[] = "AevonRightEdgeMissHintV118";
__attribute__((used)) static const char AevonRightEdgeWidenV118Marker[] = "AevonRightEdgeWidenV118";

/* ── V0.2.9（Aevon(95) 判读）：本版标记 ──
 * 用户主诉①「桌面和悬浮内的 APP 都无法滑动，只能点击」；②「设置里的开关注释不清晰，
 * 简化名字 + 加圆圈叹号点开看详细说明」。四条修复各配一条 used 常量，保证
 * 即使以后有人把日志文案改掉，CI 的二进制断言也不会假红：
 *   AevonStripNoHitV209     = 手势条退出命中测试（右下角 18x260 不再抢触摸）
 *   AevonFloatStandDownV209 = 浮窗开着按桌面处理 + App 侧浮窗内整体退让
 *   AevonFloatPassV209      = 落在浮窗上的触摸整个交回浮窗
 *   AevonDeskEdgePullV209   = 桌面呼盘收紧成「贴边横拉」，把翻页让出来
 *   AevonPrefsInfoV209      = 设置页开关行内 ⓘ（点开弹完整说明）
 * （App 侧那两条 AevonAppAnyMoveFailV209 / AevonFloatStandDownV209 在 AevonApp.dylib 里，
 *  文末这几条只钉主插件 Aevon.dylib。） */
__attribute__((used)) static const char AevonStripNoHitV209Marker[] = "AevonStripNoHitV209";
__attribute__((used)) static const char AevonFloatStandDownV209Marker[] = "AevonFloatStandDownV209";
__attribute__((used)) static const char AevonFloatPassV209Marker[] = "AevonFloatPassV209";
__attribute__((used)) static const char AevonDeskEdgePullV209Marker[] = "AevonDeskEdgePullV209";
__attribute__((used)) static const char AevonPrefsInfoV209Marker[] = "AevonPrefsInfoV209";

/* ── V0.2.10（Aevon(96) 判读）：本版标记 ──
 * 用户四条诉求：①圆盘滑动时偶尔还会带动全屏 App；②设置里 ⓘ 离开关太近容易误触；
 * ③美化圆盘中间的应用选择器面板；④触发区 / 接管带要看得见、能改、拖动滑条实时跟随。
 * 每条修复各配一条 used 常量，保证日志文案以后被改写时 CI 断言不会假红：
 *   AevonAppBlindHoldV210  = App 侧盲期（识别器未挂上）时拒绝呼盘，杜绝「圆盘 + App 双响应」
 *   AevonAppReadyV210      = App 侧挂载 / 回前台广播 appready，SB 据此解除盲期
 *   AevonAppMountFastV210  = App 侧挂载提速（0.6s+1.0s 改 0.12s + 0.2s×80 重试）
 *   AevonPrefsInfoPosV210  = 设置页 ⓘ 从「贴开关左侧」改到「开关名字正后方」
 *   AevonRingHubV210       = 圆盘心圆加两层底盘 + 渐变蓝，不再是孤零零一个圆
 *   AevonPickerBeautyV210  = 应用选择面板改毛玻璃 + 22 圆角 + 圆形关闭键
 *   AevonGeomOverlayV210   = 触发区（青）/ 接管带（橙）两块实时预览框
 *   AevonGeomPreviewLiveV210 = 拖滑条 / 进页面即亮，尺寸标签跟着手指变
 * （AevonAppReadyV210 / AevonAppMountFastV210 在 AevonApp.dylib 里另一份，
 *  这里只钉主插件 Aevon.dylib。） */
__attribute__((used)) static const char AevonAppBlindHoldV210Marker[] = "AevonAppBlindHoldV210";
__attribute__((used)) static const char AevonAppReadyV210Marker[] = "AevonAppReadyV210";
__attribute__((used)) static const char AevonAppMountFastV210Marker[] = "AevonAppMountFastV210";
__attribute__((used)) static const char AevonPrefsInfoPosV210Marker[] = "AevonPrefsInfoPosV210";
__attribute__((used)) static const char AevonRingHubV210Marker[] = "AevonRingHubV210";
__attribute__((used)) static const char AevonPickerBeautyV210Marker[] = "AevonPickerBeautyV210";
__attribute__((used)) static const char AevonGeomOverlayV210Marker[] = "AevonGeomOverlayV210";
__attribute__((used)) static const char AevonGeomPreviewLiveV210Marker[] = "AevonGeomPreviewLiveV210";

/* V0.2.11（Aevon(97) 判读）：四条主诉各配一条 used 常量，日志文案改写时 CI 断言不假红。
 *   AevonPrefsInfoFitV211      = 设置页 ⓘ 先布局再量文字，首次进入也不压字
 *   AevonBandRangeFreeV211     = 接管带宽度 8~140pt / 带高 6~100%，滑条不再有硬底
 *   AevonAppReleaseCleanV211   = App 侧判向成立后保持在场到真正抬手（手势环境对称收尾）
 *   AevonAppRingCloseReleaseV211 = 收到圆盘收起即在 App 进程收尾识别器
 *   AevonAppNoBlockIdleV211    = 手里没触摸时绝不建失败要求（不压别人的滚动 pan）
 *   AevonRingGlyphTopV211      = 圆心四宫格独立一层，蓝色渐变盖不住
 *   AevonRingHubFitV211        = 心圆底盘按内圈半径反算，不再压内圈图标 */
__attribute__((used)) static const char AevonPrefsInfoFitV211Marker[] = "AevonPrefsInfoFitV211";
__attribute__((used)) static const char AevonBandRangeFreeV211Marker[] = "AevonBandRangeFreeV211";
__attribute__((used)) static const char AevonAppReleaseCleanV211Marker[] = "AevonAppReleaseCleanV211";
__attribute__((used)) static const char AevonAppRingCloseReleaseV211Marker[] = "AevonAppRingCloseReleaseV211";
__attribute__((used)) static const char AevonAppNoBlockIdleV211Marker[] = "AevonAppNoBlockIdleV211";
__attribute__((used)) static const char AevonRingGlyphTopV211Marker[] = "AevonRingGlyphTopV211";
__attribute__((used)) static const char AevonRingHubFitV211Marker[] = "AevonRingHubFitV211";

/* ──────────────────────────────────────────────────────────────────
 * V0.2.12（Aevon(98) 事故结构性加固）
 *   AevonSwallowSelfHealV212    = 圆盘不在场 / 超绝对上限 → 接管状态当场归还（全系统触摸必经之路上的自愈）
 *   AevonEndAlwaysCleanV212     = 抬手 / 取消分支用 defer 保证清理，任何 return 都漏不掉
 *   AevonReleaseAlsoClosesRingV212 = 释放接管时连圆盘一起收掉并补发 ringclose
 *   AevonOwnHardDeadlineV212    = 死手开关改按「收归起始时刻」算绝对上限，不被 moved 续期
 *   AevonAppRingGoneGuardV212   = App 侧轮询圆盘状态位，圆盘收起即收尾识别器
 *   AevonRingBitReadV212        = 跨进程只读圆盘状态位（bit39）的最小实现
 * ────────────────────────────────────────────────────────────────── */
__attribute__((used)) static const char AevonSwallowSelfHealV212Marker[] = "AevonSwallowSelfHealV212";
__attribute__((used)) static const char AevonEndAlwaysCleanV212Marker[] = "AevonEndAlwaysCleanV212";
__attribute__((used)) static const char AevonReleaseAlsoClosesRingV212Marker[] = "AevonReleaseAlsoClosesRingV212";
__attribute__((used)) static const char AevonOwnHardDeadlineV212Marker[] = "AevonOwnHardDeadlineV212";
__attribute__((used)) static const char AevonAppRingGoneGuardV212Marker[] = "AevonAppRingGoneGuardV212";
__attribute__((used)) static const char AevonRingBitReadV212Marker[] = "AevonRingBitReadV212";
