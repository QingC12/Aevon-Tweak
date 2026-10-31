#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/**
 * V0.1.7（AevonShieldV107 / AevonObjCProbeV107）
 *
 * 这个文件存在的理由，是 V0.1.6 用两次「自动注销」换来的：
 *
 *   ① Swift 的 `as?` 会对来源不明的对象发起动态类型转换。
 *      归档(13) / Aevon(74) 的崩溃栈就是这一串：
 *        swift_dynamicCast → swift_getObjectType → _CF_forwarding_prep_0 → 陷阱(SIGTRAP)
 *      而全进程类表扫描（objc_copyClassList）在 Swift 里恰恰要经过那一步 ——
 *      所以这类动作一律搬进 ObjC：Class * 数组就是 Class，不经过任何 Swift 转换。
 *
 *   ② Swift 的 do/catch **捕不到** `doesNotRecognizeSelector:` 抛出的
 *      NSInvalidArgumentException —— 它直接把进程终结掉。ObjC 的 @try/@catch 能捕。
 *
 * V0.2.81（AevonDeadCodeV281）：原本这里还有 `AevonAllClassNames` / `AevonMethodNamesForClass`
 * / `AevonIvarNamesForClass` / 识别器三件套 / `AevonObjectIvarSummary` / `AevonClassFactoryObject`
 * 六个函数 —— 它们唯一的调用者是 V0.1.7 与 V0.1.14 的两套启动探针（AevonProbeV107 /
 * AevonProbeP7V114）。那两套探针本版已整体退役（类表枚举自 0.2.72 起被永久封印、剩下
 * 的定向探测结论早已落进日志与逆向报告），六个函数随之删除。
 * `AevonSealP1V276` 封印令标记按「历史标记只加不改」保留在断言垫片里。
 *
 * 纪律：本文件剩下的函数全部**只读**，不 swizzle、不 addMethod、不碰任何业务状态。
 */

NSString *AevonShieldRun(void (^block)(void)) {
    if (block == nil) { return nil; }
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *name = exception.name ?: @"?";
        NSString *reason = exception.reason ?: @"?";
        // reason 里通常带完整调用栈，截断到 300 字符即可（日志要能一口气看完）。
        if (reason.length > 300) {
            reason = [[reason substringToIndex:300] stringByAppendingString:@"…"];
        }
        return [NSString stringWithFormat:@"%@ | %@", name, reason];
    } @catch (...) {
        return @"未知异常（非 NSException）";
    }
}

NSString *AevonSafeClassName(id object) {
    if (object == nil) { return nil; }
    Class cls = object_getClass(object);
    if (cls == Nil) { return nil; }
    const char *name = class_getName(cls);
    if (name == NULL || name[0] == '\0') { return nil; }
    return [NSString stringWithUTF8String:name];
}

/// 对象是否实现了某个方法 —— 用 class_respondsToSelector 查，**不向对象发消息**。
/// （对来源不明的对象发 respondsToSelector: 本身就是一次 ObjC 消息，野对象会当场转发崩掉。）
BOOL AevonObjectResponds(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) { return NO; }
    Class cls = object_getClass(object);
    if (cls == Nil) { return NO; }
    SEL selector = NSSelectorFromString(selectorName);
    if (selector == NULL) { return NO; }
    return class_respondsToSelector(cls, selector);
}

/// 类（含元类）的实例/类方法名清单。**定向名单专用**：只对传入的类名做
/// class_copyMethodList，绝不遍历全进程类表（0.2.72 封印令）。
/// 调用者：AevonWindowView 的开窗路线探测（FBSceneManager / SBDeviceApplicationSceneViewController）。
NSArray<NSString *> *AevonMethodNamesForClass(NSString *className) {
    if (className.length == 0) { return @[]; }
    Class cls = NSClassFromString(className);
    if (cls == Nil) { return @[]; }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    unsigned int count = 0;

    Method *methods = class_copyMethodList(cls, &count);
    if (methods != NULL) {
        for (unsigned int index = 0; index < count; index++) {
            NSString *selector = NSStringFromSelector(method_getName(methods[index]));
            if (selector.length > 0) { [names addObject:selector]; }
        }
        free(methods);
    }

    Class meta = object_getClass(cls);
    if (meta != Nil) {
        count = 0;
        methods = class_copyMethodList(meta, &count);
        if (methods != NULL) {
            for (unsigned int index = 0; index < count; index++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[index]));
                if (selector.length > 0) { [names addObject:[@"+" stringByAppendingString:selector]]; }
            }
            free(methods);
        }
    }
    return names;
}

/// 视图宿主链：本视图(frame) ↑ 父视图(frame) ↑ … ，最多 depth 级。
NSString *AevonViewHostChain(id view, NSInteger depth) {
    if (view == nil) { return @"nil"; }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    @try {
        id cursor = view;
        NSInteger guard = 0;
        while (cursor != nil && guard < depth) {
            NSString *className = AevonSafeClassName(cursor) ?: @"?";
            CGRect rect = CGRectZero;
            if ([cursor isKindOfClass:[UIView class]]) {
                rect = ((UIView *)cursor).frame;
            }
            [parts addObject:[NSString stringWithFormat:@"%@(%.0f,%.0f)", className, rect.origin.x, rect.origin.y]];
            if (![cursor isKindOfClass:[UIView class]]) { break; }
            cursor = ((UIView *)cursor).superview;
            guard++;
        }
    } @catch (NSException *exception) {
        return @"宿主链中断（已兜住）";
    }
    return [parts componentsJoinedByString:@" ↑ "];
}

/* ── V0.3.37 二进制标记（AevonDockLiveV337）────────────────────────────
 * 停靠期回到实时画面（不降后台 / 三拍撤封面 / 掉画补前台）的产品标记。
 * 独立成一条纯 ASCII C 串：Swift 日志串里的标记虽然也能被 strings 抓到，
 * 但 __cstring 里有一条独立串最稳（0.3.33 的教训：夹在中文串里本地审计抓不到）。 */
__attribute__((used, unused)) static const char AevonDockLiveMark337[] = "AevonDockLiveV337";
