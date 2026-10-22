#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/*
 * 全局触摸通道（V0.0.23）。
 *
 * 为什么必须下沉到这一层：
 *   Aevon(16) 日志的证据是「右侧白条可见、但 App 前台整场零『手势区收到触摸』」，
 *   而同一时刻悬浮球（同一个容器里的兄弟视图）点击是好的 —— 说明容器本身在 App 画面里，
 *   只是 `SBDeviceApplicationSceneViewController.view` 的命中测试把靠右边缘的触摸
 *   直接交给了 App 画面，我们的手势条永远排不上队。
 *   继续在视图层调几何 / 调层级都无解，只能从事件总入口拿。
 *
 * 做法：
 *   hook 进程内 `UIApplication -sendEvent:`（SpringBoard 的所有触摸都会经过这里），
 *   在调用原实现**之后**把每个变化中的触摸（began / moved / ended / cancelled）
 *   连同触摸身份（指针地址）与坐标上报给 Swift 侧。
 *   完全不消费事件、不改变任何系统行为，Swift 侧只做「右边缘左滑 / 长按」判定，
 *   命中才呼出圆盘；没命中就当它不存在。
 *
 * 安全：
 *   · 只在用户开启插件且开关打开时安装（由 Swift 侧控制安装时机）；
 *   · 全程 @try/@catch，任何异常都不外抛；
 *   · 找不到方法时静默跳过并返回 NO，调用方继续用原有的视图通道兜底。
 */

extern void AevonGlobalTouchPhase(NSInteger phase, uintptr_t touchID, CGFloat x, CGFloat y);

static IMP AevonOrigSendEvent = NULL;
static BOOL AevonTouchHookInstalled = NO;
static BOOL AevonTouchHookFailed = NO;

static void AevonHookSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (AevonOrigSendEvent) {
        ((void (*)(id, SEL, UIEvent *))AevonOrigSendEvent)(self, _cmd, event);
    }
    @try {
        NSSet<UITouch *> *touches = [event allTouches];
        if (touches.count == 0) { return; }
        for (UITouch *touch in touches) {
            UITouchPhase phase = touch.phase;
            if (phase != UITouchPhaseBegan && phase != UITouchPhaseMoved &&
                phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled) {
                continue;
            }
            CGPoint point = [touch locationInWindow];
            AevonGlobalTouchPhase((NSInteger)phase,
                                  (uintptr_t)(__bridge void *)touch,
                                  point.x, point.y);
        }
    } @catch (NSException *exception) {
        // 私有路径出错绝不影响 SpringBoard
    }
}

/// 找到「真正自己实现了 sendEvent:」的那个类：SpringBoard 的 app 类是 UIApplication 的子类，
/// 只改父类可能与子类实现无关，所以沿继承链往上找第一个自有实现。
static Class AevonFindSendEventOwner(Class start) {
    Class current = start;
    while (current != Nil && current != [NSObject class]) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        BOOL found = NO;
        if (methods != NULL) {
            for (unsigned int i = 0; i < count; i++) {
                if (method_getName(methods[i]) == @selector(sendEvent:)) { found = YES; break; }
            }
            free(methods);
        }
        if (found) { return current; }
        current = class_getSuperclass(current);
    }
    return Nil;
}

BOOL AevonTouchHookInstall(void) {
    if (AevonTouchHookInstalled) { return YES; }
    if (AevonTouchHookFailed) { return NO; }
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { AevonTouchHookFailed = YES; return NO; }
        Class owner = AevonFindSendEventOwner(object_getClass(app));
        if (owner == Nil) { owner = [UIApplication class]; }
        Method method = class_getInstanceMethod(owner, @selector(sendEvent:));
        if (method == NULL) { AevonTouchHookFailed = YES; return NO; }
        AevonOrigSendEvent = method_setImplementation(method, (IMP)AevonHookSendEvent);
        AevonTouchHookInstalled = (AevonOrigSendEvent != NULL);
        return AevonTouchHookInstalled;
    } @catch (NSException *exception) {
        AevonTouchHookFailed = YES;
        return NO;
    }
}
