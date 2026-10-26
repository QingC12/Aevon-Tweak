#import "../AevonSysEdgeShim.h"
#import <objc/runtime.h>
#import <objc/message.h>

/*
 * V0.2.13（AevonSysEdgeV213）—— 右缘呼出改走系统手势管线的「withType」接口。
 *
 * 本文件只做四件事，全部是「摸系统私有 API」：
 *   ① 用 `UIScreenEdgePanGestureRecognizer` 的私有 init 造识别器；
 *   ② 把识别器登记进系统手势管理器（优先 withType:，其次 toDisplayWithIdentity:）；
 *   ③ 让自编的 type 编号被系统放行；
 *   ④ 把每一步的成败如实报给 Swift 侧，由策略层决定回退。
 *
 * 纪律：
 *   · 任何一步失败都静默返回 NO / nil，绝不 @throw、绝不 crash；
 *   · 类/方法一律先 `NSClassFromString` + `respondsToSelector` 验存在再调用；
 *   · 不改系统方法的原实现（只装 IMP 转发），避免把 SpringBoard 的手势判断弄坏。
 */

/* ── CI 标记（历史校验串只加不改；这些字面量必然留在 __cstring 里）── */
__attribute__((used)) static const char AevonSysEdgeV213Tag[] = "AevonSysEdgeV213";
__attribute__((used)) static const char AevonSysEdgeWithTypeV213Tag[] = "AevonSysEdgeWithTypeV213";
__attribute__((used)) static const char AevonSysEdgeAllowTypeV213Tag[] = "AevonSysEdgeAllowTypeV213";
__attribute__((used)) static const char AevonSysEdgePrivInitV213Tag[] = "AevonSysEdgePrivInitV213";
__attribute__((used)) static const char AevonSysEdgeRegionV213Tag[] = "AevonSysEdgeRegionV213";

static NSString *AevonLastRegisterPath = @"";

NSString *AevonSysEdgeLastRegisterPath(void) {
    return AevonLastRegisterPath ?: @"";
}

#pragma mark - 私有 init（造边缘识别器）

/*
 * UIScreenEdgePanGestureRecognizer 的私有初始化器有两个重载：
 *   -initWithTarget:action:type:options:   （Triggr 用的这个，带 options）
 *   -initWithTarget:action:type:           （更早的版本只有这个）
 * 公开的 -initWithTarget:action: 造出来的识别器**不带 type**，
 * 进不了系统手势管线（系统按 type 认手势归属），所以必须走私有的。
 *
 * type 传 2：Triggr 在 iOS 16.2 真机手测过「type 2 as SpringBoard's own」。
 *            注意它同时还 hook 了 _isGestureWithTypeAllowed:，
 *            说明「借用系统编号」和「自编编号+放行」两条都得能走。
 */
typedef id (*AevonInit4IMP)(id, SEL, id, SEL, long long, unsigned long long);
typedef id (*AevonInit3IMP)(id, SEL, id, SEL, long long);
typedef void (*AevonSetDoubleIMP)(id, SEL, double);

UIGestureRecognizer *AevonSysEdgeCreateRecognizer(id target, SEL action,
                                                  NSInteger type, double edgeRegionSize) {
    Class cls = NSClassFromString(@"UIScreenEdgePanGestureRecognizer");
    if (!cls) {
        return nil;
    }

    id recognizer = nil;
    @try {
        id allocated = [cls alloc];
        if (!allocated) {
            return nil;
        }

        SEL four = NSSelectorFromString(@"initWithTarget:action:type:options:");
        SEL three = NSSelectorFromString(@"initWithTarget:action:type:");

        if ([allocated respondsToSelector:four]) {
            AevonInit4IMP fn = (AevonInit4IMP)(void *)objc_msgSend;
            recognizer = fn(allocated, four, target, action, (long long)type, (unsigned long long)0);
        } else if ([allocated respondsToSelector:three]) {
            AevonInit3IMP fn = (AevonInit3IMP)(void *)objc_msgSend;
            recognizer = fn(allocated, three, target, action, (long long)type);
        }

        if (!recognizer) {
            return nil;
        }

        /* 只认右缘：本插件的入口是「右缘左滑」。 */
        if ([recognizer respondsToSelector:@selector(setEdges:)]) {
            ((void (*)(id, SEL, UIRectEdge))(void *)objc_msgSend)(recognizer,
                                                                  @selector(setEdges:),
                                                                  UIRectEdgeRight);
        }

        /*
         * 边缘区宽度。系统默认值偏窄（实测约 20pt 上下，随设备变化），
         * Aevon 的既有热区是 46pt、历史落点分布在距右缘 12/19/25/42pt，
         * 所以策略层会给一个比默认略宽的值 —— 但这一项**只影响判定起点**，
         * 不影响「识别成功后取消 App 触摸」的语义。
         */
        SEL region = NSSelectorFromString(@"_setEdgeRegionSize:");
        if (edgeRegionSize > 0 && [recognizer respondsToSelector:region]) {
            AevonSetDoubleIMP fn = (AevonSetDoubleIMP)(void *)objc_msgSend;
            fn(recognizer, region, edgeRegionSize);
        }
    } @catch (...) {
        return nil;
    }

    return recognizer;
}

#pragma mark - displayIdentity

/*
 * 两参登记要一个 FBSDisplayIdentity。两条取法（Aevon(75) 探针实测两条都通）：
 *   ① FBDisplayManager.mainConfiguration.identity —— 首选；
 *   ② UIWindowScene.displayIdentity —— ScreenCore（Stheno）走的是这条。
 * 取不到就返回 nil，调用方改走单参重载。
 */
static id AevonDisplayIdentity(void) {
    id identity = nil;
    @try {
        Class manager = NSClassFromString(@"FBDisplayManager");
        if (manager) {
            SEL mainSel = NSSelectorFromString(@"mainConfiguration");
            if ([manager respondsToSelector:mainSel]) {
                id config = ((id (*)(id, SEL))(void *)objc_msgSend)(manager, mainSel);
                if (config) {
                    SEL idSel = NSSelectorFromString(@"identity");
                    if ([config respondsToSelector:idSel]) {
                        identity = ((id (*)(id, SEL))(void *)objc_msgSend)(config, idSel);
                    }
                }
            }
        }

        if (!identity) {
            Class appCls = NSClassFromString(@"UIApplication");
            if (appCls) {
                SEL sharedSel = NSSelectorFromString(@"sharedApplication");
                id app = ((id (*)(id, SEL))(void *)objc_msgSend)(appCls, sharedSel);
                SEL scenesSel = NSSelectorFromString(@"connectedScenes");
                if (app && [app respondsToSelector:scenesSel]) {
                    NSSet *scenes = ((id (*)(id, SEL))(void *)objc_msgSend)(app, scenesSel);
                    for (id scene in scenes) {
                        SEL displaySel = NSSelectorFromString(@"displayIdentity");
                        if ([scene respondsToSelector:displaySel]) {
                            identity = ((id (*)(id, SEL))(void *)objc_msgSend)(scene, displaySel);
                            if (identity) { break; }
                        }
                    }
                }
            }
        }
    } @catch (...) {
        return nil;
    }
    return identity;
}

#pragma mark - 登记

/* 候选管理器与其工厂方法。顺序即优先级：
 *   SBSystemGestureManager.mainDisplayManager —— Triggr 用的这个（withType 接口在此）；
 *   _UISystemGestureManager.sharedInstance    —— Aevon(75) 实测 two:1，老路验证过；
 *   SBMainDisplaySystemGestureManager         —— 兼容旧版本。
 */
static NSArray<NSArray<NSString *> *> *AevonManagerCandidates(void) {
    return @[
        @[@"SBSystemGestureManager", @"mainDisplayManager"],
        @[@"SBSystemGestureManager", @"sharedInstance"],
        @[@"_UISystemGestureManager", @"sharedInstance"],
        @[@"SBMainDisplaySystemGestureManager", @"sharedInstance"],
        @[@"SBMainDisplaySystemGestureManager", @"mainDisplayManager"],
    ];
}

static id AevonManagerObject(NSString *className, NSString *factoryName) {
    Class cls = NSClassFromString(className);
    if (!cls) { return nil; }
    SEL factory = NSSelectorFromString(factoryName);
    if (![cls respondsToSelector:factory]) { return nil; }
    id object = nil;
    @try {
        object = ((id (*)(id, SEL))(void *)objc_msgSend)(cls, factory);
    } @catch (...) {
        return nil;
    }
    return object;
}

BOOL AevonSysEdgeRegister(UIGestureRecognizer *recognizer, unsigned long long type) {
    if (!recognizer) { return NO; }

    SEL withType = NSSelectorFromString(@"addGestureRecognizer:withType:");
    SEL withIdentity = NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:");
    SEL single = NSSelectorFromString(@"addGestureRecognizer:");

    id identity = AevonDisplayIdentity();

    for (NSArray<NSString *> *candidate in AevonManagerCandidates()) {
        id manager = AevonManagerObject(candidate[0], candidate[1]);
        if (!manager) { continue; }

        @try {
            /*
             * ① withType: —— 本版新增的尝试点。
             *    真机探针只测过 toDisplayWithIdentity:（two:1 / acq 位），
             *    这个带 type 的重载从未被验证；Triggr 在 iOS 16.2 上用它成功注册了四种边缘手势。
             */
            if ([manager respondsToSelector:withType]) {
                ((void (*)(id, SEL, id, unsigned long long))(void *)objc_msgSend)(manager,
                                                                                 withType,
                                                                                 recognizer,
                                                                                 type);
                AevonLastRegisterPath = [NSString stringWithFormat:@"%@.%@ addGestureRecognizer:withType:",
                                         candidate[0], candidate[1]];
                return YES;
            }

            /* ② toDisplayWithIdentity: —— 0.1.5~0.1.13 验证过能登记成功的那条。 */
            if (identity && [manager respondsToSelector:withIdentity]) {
                ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(manager,
                                                                  withIdentity,
                                                                  recognizer,
                                                                  identity);
                AevonLastRegisterPath = [NSString stringWithFormat:@"%@.%@ addGestureRecognizer:toDisplayWithIdentity:(%@)",
                                         candidate[0], candidate[1],
                                         NSStringFromClass([identity class])];
                return YES;
            }

            /* ③ 单参 —— 最后一档，可能只是把识别器挂上而不进管线，仅作兜底。 */
            if ([manager respondsToSelector:single]) {
                ((void (*)(id, SEL, id))(void *)objc_msgSend)(manager, single, recognizer);
                AevonLastRegisterPath = [NSString stringWithFormat:@"%@.%@ addGestureRecognizer:（单参兜底，进不进管线未定）",
                                         candidate[0], candidate[1]];
                return YES;
            }
        } @catch (...) {
            continue;
        }
    }

    AevonLastRegisterPath = @"未找到可用管理器";
    return NO;
}

#pragma mark - 让自编 type 被放行

/*
 * Triggr 的注释与实现都指向同一件事：自编 type 必须被这两个方法放行，否则
 * 识别器挂上了也不会真正参与系统手势判定。
 *   -_isGestureWithTypeAllowed:
 *   -_shouldEnableSystemGestureWithType:
 * 做法：只对 base ~ base+count 返回 YES，其余原样转交原 IMP。
 */
static BOOL (*AevonOrigTypeAllowed)(id, SEL, unsigned long long) = NULL;
static BOOL (*AevonOrigShouldEnable)(id, SEL, unsigned long long) = NULL;
static unsigned long long AevonAllowedBase = 0;
static unsigned long long AevonAllowedCount = 0;

static BOOL AevonTypeAllowedHook(id self, SEL _cmd, unsigned long long type) {
    if (AevonAllowedCount > 0 && type >= AevonAllowedBase && type < AevonAllowedBase + AevonAllowedCount) {
        return YES;
    }
    if (AevonOrigTypeAllowed) {
        return AevonOrigTypeAllowed(self, _cmd, type);
    }
    return NO;
}

static BOOL AevonShouldEnableHook(id self, SEL _cmd, unsigned long long type) {
    if (AevonAllowedCount > 0 && type >= AevonAllowedBase && type < AevonAllowedBase + AevonAllowedCount) {
        return YES;
    }
    if (AevonOrigShouldEnable) {
        return AevonOrigShouldEnable(self, _cmd, type);
    }
    return NO;
}

BOOL AevonSysEdgeAllowTypes(unsigned long long base, unsigned long long count) {
    if (count == 0) { return NO; }

    AevonAllowedBase = base;
    AevonAllowedCount = count;

    Class cls = NSClassFromString(@"SBSystemGestureManager");
    if (!cls) {
        return NO;
    }

    BOOL installed = NO;
    @try {
        SEL allowedSel = NSSelectorFromString(@"_isGestureWithTypeAllowed:");
        Method allowed = class_getInstanceMethod(cls, allowedSel);
        if (allowed) {
            if (!AevonOrigTypeAllowed) {
                AevonOrigTypeAllowed = (BOOL (*)(id, SEL, unsigned long long))method_getImplementation(allowed);
            }
            method_setImplementation(allowed, (IMP)AevonTypeAllowedHook);
            installed = YES;
        }

        SEL enableSel = NSSelectorFromString(@"_shouldEnableSystemGestureWithType:");
        Method enable = class_getInstanceMethod(cls, enableSel);
        if (enable) {
            if (!AevonOrigShouldEnable) {
                AevonOrigShouldEnable = (BOOL (*)(id, SEL, unsigned long long))method_getImplementation(enable);
            }
            method_setImplementation(enable, (IMP)AevonShouldEnableHook);
            installed = YES;
        }
    } @catch (...) {
        return installed;
    }

    return installed;
}

#pragma mark - 强制失败（归还触摸）

/*
 * `UIGestureRecognizer.state` 在 Swift 侧只读，只有识别器自己的子类能在内部改。
 * 本项目的策略层是 Swift，识别器是系统的 UIScreenEdgePanGestureRecognizer，
 * 没有可写的子类 —— 所以「判为纵向就 Failed」只能回到 ObjC 走私有的 -setState:。
 *
 * 为什么一定要主动 Failed：
 *   系统边缘识别器本身在「从边缘起手但几乎不动 / 纯纵向」时通常会自己失败，
 *   但那取决于系统判定时机。我们自己认出纵向就立刻置 Failed，
 *   能保证「右缘上下滑动照样滚屏」不被我们多扣几十毫秒 —— 这是本版对 Aevon
 *   历史事故（右缘带内无法滚动）最直接的防线。
 *
 * 状态值：UIGestureRecognizerStateFailed = 5（UIKit 公开枚举）。
 * 取不到 -setState: 就什么都不做 —— 让系统自己判，绝不硬改内存。
 */
void AevonSysEdgeForceFail(UIGestureRecognizer *recognizer) {
    if (!recognizer) { return; }
    SEL setState = NSSelectorFromString(@"setState:");
    if (![recognizer respondsToSelector:setState]) { return; }
    @try {
        ((void (*)(id, SEL, NSInteger))(void *)objc_msgSend)(recognizer, setState, 5);
    } @catch (...) {
        /* 静默：识别器状态改不动也不能影响 SpringBoard */
    }
}
