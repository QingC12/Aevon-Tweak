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
 * App 图标垫片。
 *
 * Stheno 逆向证据（Stheno.dylib 符号表）：它取图标走的是
 * `-applicationIconImageForBundleIdentifier:format:scale:`，宿主类为 SBIconController。
 * format 在不同 iOS 版本上取值不一致（0/2 都用过），所以两个都试一遍再放弃。
 * 全部失败时返回 nil，由 Swift 侧画首字母圆形兜底。
 */
UIImage *AevonIconImage(NSString *bundleID, CGFloat scale) {
    if (bundleID.length == 0) return nil;
    @try {
        Class ctlClass = NSClassFromString(@"SBIconController");
        if (ctlClass == Nil) return nil;
        id ctl = ((id (*)(id, SEL))objc_msgSend)(ctlClass, @selector(sharedInstance));
        if (ctl == nil) return nil;

        SEL sel = @selector(applicationIconImageForBundleIdentifier:format:scale:);
        if (![ctl respondsToSelector:sel]) return nil;

        CGFloat useScale = scale > 0 ? scale : 3.0;
        for (int format = 0; format <= 2; format++) {
            id image = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(ctl, sel, bundleID, format, useScale);
            if ([image isKindOfClass:[UIImage class]]) return (UIImage *)image;
        }
    } @catch (NSException *exception) {
        // 私有接口，任何异常都当"没有图标"
    }
    return nil;
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
