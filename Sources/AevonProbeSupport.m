#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/**
 * V0.1.7（AevonShieldV107 / AevonObjCProbeV107）
 *
 * 这个文件存在的理由只有两条，都是 V0.1.6 用两次「自动注销」换来的：
 *
 *   ① Swift 的 `as?` 会对来源不明的对象发起动态类型转换。
 *      归档(13) / Aevon(74) 的崩溃栈就是这一串：
 *        swift_dynamicCast → swift_getObjectType → _CF_forwarding_prep_0 → 陷阱(SIGTRAP)
 *      翻译过来就是「把某个不该当对象的指针当成对象去问它的类」，
 *      Objective-C 消息转发一路走到头，SpringBoard 直接死。
 *      而全进程类表扫描（objc_copyClassList）在 Swift 里恰恰要经过那一步 ——
 *      所以这一整块搬进 ObjC：Class * 数组就是 Class，不经过任何 Swift 转换。
 *
 *   ② Swift 的 do/catch **捕不到** `doesNotRecognizeSelector:` 抛出的
 *      NSInvalidArgumentException —— 它直接把进程终结掉。ObjC 的 @try/@catch 能捕，
 *      捕到以后 SpringBoard 毫发无伤，只在日志里留一条异常描述。
 *      所以每一段探针都从这里过一道闸。
 *
 * 纪律：本文件里的函数全部**只读**（copy 类表 / 读方法名 / 读类名），
 * 不 swizzle、不 addMethod、不碰任何业务状态。
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

NSArray<NSString *> *AevonAllClassNames(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) { return @[]; }
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (cls == Nil) { continue; }
        const char *name = class_getName(cls);
        if (name == NULL || name[0] == '\0') { continue; }
        NSString *text = [NSString stringWithUTF8String:name];
        if (text.length > 0) { [names addObject:text]; }
    }
    free(classes);
    return names;
}

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

NSArray<NSString *> *AevonIvarNamesForClass(NSString *className) {
    if (className.length == 0) { return @[]; }
    Class cls = NSClassFromString(className);
    if (cls == Nil) { return @[]; }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    if (ivars != NULL) {
        for (unsigned int index = 0; index < count; index++) {
            const char *name = ivar_getName(ivars[index]);
            if (name == NULL || name[0] == '\0') { continue; }
            [names addObject:[NSString stringWithUTF8String:name]];
        }
        free(ivars);
    }
    return names;
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

/// 给类发一个无参工厂消息，返回实例（取不到返 nil）。
/// 先确认类方法真的存在，绝不对着类盲发消息 —— 那会抛
/// `+[X sharedInstance]: unrecognized selector`，在 Swift 侧兜不住。
id AevonClassFactoryObject(NSString *className, NSString *selectorName) {
    if (className.length == 0 || selectorName.length == 0) { return nil; }
    Class cls = NSClassFromString(className);
    if (cls == Nil) { return nil; }
    SEL selector = NSSelectorFromString(selectorName);
    if (selector == NULL || !class_respondsToSelector(object_getClass(cls), selector)) { return nil; }
    @try {
        IMP imp = class_getMethodImplementation(object_getClass(cls), selector);
        if (imp == NULL) { return nil; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
        return fn((id)cls, selector);
    } @catch (NSException *exception) {
        return nil;
    }
}
