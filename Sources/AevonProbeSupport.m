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

/// ── V0.1.14（AevonRecognizerHostV114）：宿主审计三件套 ──
///
/// 为什么这三件必须留在 ObjC：
///   P7 要看的是「系统手势识别器到底挂在哪个视图上、覆盖哪里」。这需要沿对象 ivar
///   往下挖两层（manager → recognizers → view → superview），中间每一跳都是**来路不明的对象**。
///   Swift 侧只要出现一次 `as?` 就会走 swift_dynamicCast，而那是 V0.1.6 两次自动注销的崩溃点。
///   所以：挖的动作全部在这里，Swift 只接收已经拼好的字符串。

/// 安全调用一个「无参、返回对象」的方法：先验方法存在，再取 IMP 直调。
static id AevonCallObjectGetter(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) { return nil; }
    if (!AevonObjectResponds(object, selectorName)) { return nil; }
    SEL selector = NSSelectorFromString(selectorName);
    if (selector == NULL) { return nil; }
    @try {
        IMP imp = class_getMethodImplementation(object_getClass(object), selector);
        if (imp == NULL) { return nil; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
        return fn(object, selector);
    } @catch (NSException *exception) {
        return nil;
    }
}

/// 单个识别器的一行描述：类名 / 宿主视图 / 宿主视图 frame / delegate / 状态。
static NSString *AevonDescribeRecognizer(UIGestureRecognizer *recognizer) {
    NSString *className = AevonSafeClassName(recognizer) ?: @"?";
    UIView *host = nil;
    @try { host = recognizer.view; } @catch (NSException *exception) { host = nil; }
    NSString *hostName = host ? (AevonSafeClassName(host) ?: @"?") : @"nil";
    CGRect rect = host ? host.frame : CGRectZero;
    id delegate = nil;
    @try { delegate = recognizer.delegate; } @catch (NSException *exception) { delegate = nil; }
    NSString *delegateName = delegate ? (AevonSafeClassName(delegate) ?: @"?") : @"nil";
    NSInteger state = -1;
    @try { state = (NSInteger)recognizer.state; } @catch (NSException *exception) { state = -1; }
    BOOL enabled = NO;
    @try { enabled = recognizer.isEnabled; } @catch (NSException *exception) { enabled = NO; }
    return [NSString stringWithFormat:@"%@ view=%@ frame=(%.0f,%.0f,%.0f,%.0f) delegate=%@ state=%ld enabled=%d",
            className, hostName, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
            delegateName, (long)state, enabled ? 1 : 0];
}

/// 从一个「容器对象」里收识别器：本身是识别器就直接描述；是集合就逐个看（最多 30 个）。
static void AevonCollectRecognizers(id value, NSString *label, NSMutableArray<NSString *> *out, NSUInteger limit) {
    if (value == nil || out.count >= limit) { return; }
    if ([value isKindOfClass:[UIGestureRecognizer class]]) {
        [out addObject:[NSString stringWithFormat:@"%@ → %@", label, AevonDescribeRecognizer((UIGestureRecognizer *)value)]];
        return;
    }
    NSArray *items = nil;
    if ([value isKindOfClass:[NSArray class]]) {
        items = (NSArray *)value;
    } else if ([value isKindOfClass:[NSSet class]]) {
        items = [(NSSet *)value allObjects];
    } else if ([value isKindOfClass:[NSOrderedSet class]]) {
        items = [(NSOrderedSet *)value array];
    }
    if (items == nil) { return; }
    NSUInteger index = 0;
    for (id item in items) {
        if (index >= 30 || out.count >= limit) { break; }
        if ([item isKindOfClass:[UIGestureRecognizer class]]) {
            [out addObject:[NSString stringWithFormat:@"%@[%lu] → %@",
                            label, (unsigned long)index, AevonDescribeRecognizer((UIGestureRecognizer *)item)]];
        }
        index++;
    }
}

NSArray<NSString *> *AevonDescribeRecognizersOfObject(id owner) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (owner == nil) { return out; }
    @try {
        // ① 先看它自己有没有 gestureRecognizers（有就发一次消息，没有不发）
        id direct = AevonCallObjectGetter(owner, @"gestureRecognizers");
        if (direct != nil) {
            AevonCollectRecognizers(direct, @"gestureRecognizers", out, 40);
        }
        // ② 再沿「对象类型 ivar」挖（含父类）。只认 type encoding 首字符为 '@' 的槽位 ——
        //    其它编码（CGRect / BOOL / 结构体）拿去 object_getIvar 会拿到垃圾指针。
        for (Class cls = object_getClass(owner); cls != Nil; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            if (ivars == NULL) { continue; }
            for (unsigned int index = 0; index < count; index++) {
                if (out.count >= 40) { break; }
                const char *type = ivar_getTypeEncoding(ivars[index]);
                if (type == NULL || type[0] != '@') { continue; }
                id value = object_getIvar(owner, ivars[index]);
                if (value == nil) { continue; }
                const char *name = ivar_getName(ivars[index]);
                NSString *label = (name != NULL) ? [NSString stringWithUTF8String:name] : @"?";
                AevonCollectRecognizers(value, label, out, 40);
            }
            free(ivars);
            if (out.count >= 40) { break; }
        }
    } @catch (NSException *exception) {
        [out addObject:[NSString stringWithFormat:@"扫描中断（已兜住）：%@", exception.reason ?: @"?"]];
    }
    return out;
}

/// 对象上所有「对象类型 ivar」的 `名字=类名` 摘要（只看一层，不递归）。
NSString *AevonObjectIvarSummary(id object) {
    if (object == nil) { return @"nil"; }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    @try {
        for (Class cls = object_getClass(object); cls != Nil; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            if (ivars == NULL) { continue; }
            for (unsigned int index = 0; index < count; index++) {
                const char *type = ivar_getTypeEncoding(ivars[index]);
                if (type == NULL || type[0] != '@') { continue; }
                const char *name = ivar_getName(ivars[index]);
                if (name == NULL) { continue; }
                id value = object_getIvar(object, ivars[index]);
                NSString *valueName = value ? (AevonSafeClassName(value) ?: @"?") : @"nil";
                [parts addObject:[NSString stringWithFormat:@"%s=%@", name, valueName]];
                if (parts.count >= 24) { break; }
            }
            free(ivars);
            if (parts.count >= 24) { break; }
        }
    } @catch (NSException *exception) {
        return @"扫描中断（已兜住）";
    }
    return parts.count > 0 ? [parts componentsJoinedByString:@" "] : @"无对象 ivar";
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
        // 用 void * 中转再 __bridge 回来：直接把 IMP 转成「返回 id」的函数指针，
        // 在 ARC 下会被当成持有语义不明的返回值，容易编译报错；这样写没有任何歧义。
        void *(*fn)(id, SEL) = (void *(*)(id, SEL))imp;
        void *raw = fn((id)cls, selector);
        return (__bridge id)raw;
    } @catch (NSException *exception) {
        return nil;
    }
}
