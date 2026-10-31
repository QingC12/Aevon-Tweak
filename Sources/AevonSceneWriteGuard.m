/* AevonSceneWriteGuard.m —— V0.3.42（AevonWriteGuardV342）
 *
 * 在系统的「写通道」上修正参数：让承载中场景的 `foreground=NO` **根本不落地**。
 *
 * 为什么是这里（0.3.41 普查定档，Aevon(112) 日志）
 * ------------------------------------------------
 * 三次回桌面掉画的现场完全一致：
 *     fg=0  dr=0  active=1  cs=0
 *     pm=UIScenePresentationManager 在、呈现层=1 在、client=FBApplicationProcess 一直连着
 * 也就是说**承载链路是健康的**，掉的是「内容」这一档；而同一瞬间唯一变化的就是
 * `settings.foreground` 1→0。App 收到「我进后台了」→ 自己把实时表面换成快照 →
 * contentState 2→0(1)→2。用户看到的「闪黑一下 → 模糊快照 → 实时」正是系统
 * contentState 的三档，不是我们盖的帧。
 *
 * 而且第三次掉画**此前 1.1 秒内零写入**（0.3.40 的「cs=2 零写铁律」全程生效）——
 * 写入从来不是掉画的原因。反过来，0.3.34~0.3.41 八版都在「系统写完 NO 之后追着改」，
 * 那个往返本身就是黑一下再亮一下。所以唯一能让 cs 永不离开 2 的做法，是在系统
 * **写下这一笔之前**把它改掉。
 *
 * 挂点（都是 17.3.1 上实测存在的，不猜）
 * ------------------------------------
 *   1. `-[UIApplicationSceneDeactivationManager _setDeactivationReasons:onScene:withSettings:reason:]`
 *      —— 本机日志 `[保活] 普查 管理器实例方法` 里实锤存在；Stheno / TrollOpen 同款。
 *   2. `-[SBSceneManager _scene:willUpdateWithSettings:transitionContext:]`
 *      —— 0.3.41 普查方法表实锤存在（typeEncoding `v40@0:8@16@24@32`）。
 *   3. `-[FBScene updateSettings:withTransitionContext:completion:]`
 *      —— 我们 0.2.78 起就挂着；历史日志里从未命中过（说明 1/2 才是真通道），
 *         仍接同一个修正函数，命中就是白赚。
 *
 * 三条纪律
 * --------
 *   ① **不新增任何写入**：只改系统本来就要交出去的那一份 settings，绝不自己再发
 *      updateSettings（V0.1.5 归档(14) 的 SIGTRAP 就栽在自发写入）。
 *   ② **能原地改就原地改**：对象本身可写就直接写它的字段，不做副本；只有不可写时
 *      才 mutableCopy 一份交回去（形式与 Stheno / TrollOpen 一致）。
 *   ③ **一切包 @try/@catch**：`setValue:forKey:` 在不可写对象上抛的是 NSException，
 *      **Swift 抓不到**，跑在 SpringBoard 里就是一次注销。所以本文件是 ObjC。
 *
 * 只对「浮窗承载中」的场景生效：集合由 AevonForegroundManager 的开窗/关窗镜像过来，
 * 未开窗时集合为空 ⇒ 本文件与原生系统行为逐字一致。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

/* 标记必须落成 ASCII C 串：注释与中文串都不进二进制（0.3.28 的教训）。 */
__attribute__((used)) static const char AevonWriteGuardV342[] = "AevonWriteGuardV342";
__attribute__((used)) static const char AevonWriteGuardHoldV342[] = "AevonWriteGuardHoldV342";
__attribute__((used)) static const char AevonWriteGuardPassV342[] = "AevonWriteGuardPassV342";
__attribute__((used)) static const char AevonWriteGuardOffV342[] = "AevonWriteGuardOffV342";

/* Swift 侧日志桥（@_cdecl("AevonWriteGuardLog")）。失败绝不影响任何路径。 */
extern void AevonWriteGuardLog(const char *detail);

static void aevg_log(NSString *line) {
    if (line == nil) { return; }
    @try {
        AevonWriteGuardLog(line.UTF8String);
    } @catch (NSException *exception) {
        /* 日志失败绝不影响写通道 */
    }
}

/* ---- 状态：承载中的场景 + 是否允许改写 ------------------------ */

static BOOL gInstalled = NO;      /* hook 是否装上了 */
static BOOL gWantHold = NO;       /* 是否允许改写（浮窗在场） */
static NSTimeInterval gHoldUntil = 0;   /* 安全阀：过期自动放行，防登记泄漏永久强撑 */
static NSMutableSet<NSString *> *gBundles = nil;
static NSMutableSet<NSString *> *gSceneIDs = nil;
static NSInteger gRewrites = 0;
/* 上限：一扇窗的生命周期里最多拦这么多笔。到了就放行 —— 说明有别的东西在
 * 疯狂写前台，再拦下去只会掩盖真正的病因，不如让它掉、我们看日志。 */
static const NSInteger kRewriteCap = 4000;

static NSString *aevg_str(id obj) {
    if (obj == nil) { return nil; }
    @try {
        if ([obj isKindOfClass:[NSString class]]) { return (NSString *)obj; }
        if ([obj respondsToSelector:@selector(identifier)]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(identifier));
            if ([v isKindOfClass:[NSString class]]) { return (NSString *)v; }
        }
    } @catch (NSException *exception) {
        return nil;
    }
    return nil;
}

/* ---- 对外：登记 / 允许 / 禁止（都由 Swift 侧调用） ------------ */

void AevonWriteGuardSetScene(const char *bundleID, const char *sceneID, int add) {
    @try {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gBundles = [NSMutableSet set];
            gSceneIDs = [NSMutableSet set];
        });
        NSString *bid = (bundleID != NULL) ? [NSString stringWithUTF8String:bundleID] : nil;
        NSString *sid = (sceneID != NULL) ? [NSString stringWithUTF8String:sceneID] : nil;
        @synchronized (gBundles) {
            if (add) {
                if (bid.length > 0) { [gBundles addObject:bid]; }
                if (sid.length > 0) { [gSceneIDs addObject:sid]; }
            } else {
                if (bid.length > 0) { [gBundles removeObject:bid]; }
                if (sid.length > 0) { [gSceneIDs removeObject:sid]; }
            }
        }
    } @catch (NSException *exception) {
        /* 登记失败只是不拦，绝不影响开窗 */
    }
}

void AevonWriteGuardRefresh(void) {
    /* 每拍调用（窗口看门计时器）。刷新安全阀，不改变「有没有场景」这个事实。 */
    gWantHold = YES;
    gHoldUntil = [NSDate timeIntervalSinceReferenceDate] + 6.0;
}

void AevonWriteGuardClear(void) {
    gWantHold = NO;
    gHoldUntil = 0;
}

static BOOL aevg_scene_held(NSString *identifier) {
    if (identifier.length == 0) { return NO; }
    @synchronized (gBundles) {
        if (gSceneIDs.count == 0 && gBundles.count == 0) { return NO; }
        if ([gSceneIDs containsObject:identifier]) { return YES; }
        for (NSString *bid in gBundles) {
            if (bid.length > 0 && [identifier rangeOfString:bid].location != NSNotFound) {
                return YES;
            }
        }
    }
    return NO;
}

/* ---- 核心：把系统要交出去的那份 settings 修正成「仍在前台」 ---- */

static id aevg_fix(id settings, id scene) {
    if (!gInstalled || !gWantHold) { return settings; }
    if (settings == nil || scene == nil) { return settings; }
    if ([NSDate timeIntervalSinceReferenceDate] > gHoldUntil) { return settings; }
    if (gRewrites >= kRewriteCap) { return settings; }

    @try {
        NSString *identifier = aevg_str(scene);
        if (!aevg_scene_held(identifier)) { return settings; }

        /* 现读：已经是「前台 + 零停用原因」就一个字都不改（零开销直通）。 */
        id fgValue = nil;
        id drValue = nil;
        @try { fgValue = [settings valueForKey:@"foreground"]; } @catch (NSException *e) { fgValue = nil; }
        @try { drValue = [settings valueForKey:@"deactivationReasons"]; } @catch (NSException *e) { drValue = nil; }

        BOOL alreadyOn = [fgValue respondsToSelector:@selector(boolValue)] ? [fgValue boolValue] : NO;
        unsigned long long drNow = [drValue respondsToSelector:@selector(unsignedLongLongValue)]
                                     ? [drValue unsignedLongLongValue] : 0ULL;
        if (alreadyOn && drNow == 0ULL) { return settings; }

        /* ② 能原地改就原地改；不可写才做一份副本交回去。 */
        id target = settings;
        BOOL canSetForeground = [settings respondsToSelector:NSSelectorFromString(@"setForeground:")];
        if (!canSetForeground) {
            if ([settings respondsToSelector:@selector(mutableCopy)]) {
                id copy = ((id (*)(id, SEL))objc_msgSend)(settings, @selector(mutableCopy));
                if (copy != nil) { target = copy; }
            }
        }
        if (target == settings && !canSetForeground) { return settings; }

        @try { [target setValue:@YES forKey:@"foreground"]; } @catch (NSException *e) { }
        @try { [target setValue:@0 forKey:@"deactivationReasons"]; } @catch (NSException *e) { }

        /* 复核：没改成就原样放行（绝不把半改的对象交出去）。 */
        id fgAfter = nil;
        @try { fgAfter = [target valueForKey:@"foreground"]; } @catch (NSException *e) { fgAfter = nil; }
        if (![fgAfter respondsToSelector:@selector(boolValue)] || ![fgAfter boolValue]) {
            return settings;
        }

        gRewrites += 1;
        if (gRewrites == 1 || gRewrites == 2 || gRewrites == 3 || (gRewrites % 100) == 0) {
            aevg_log([NSString stringWithFormat:@"拦下前台回收第 %ld 笔：%@（dr %llu→0，fg→YES，%@）"
                                                "（AevonWriteGuardV342 AevonWriteGuardHoldV342）",
                                                (long)gRewrites, identifier ?: @"?",
                                                drNow, (target == settings) ? @"原地" : @"副本"]);
        }
        return target;
    } @catch (NSException *exception) {
        /* 任何异常 → 原样放行。宁可闪一下，也绝不带走 SpringBoard。 */
        return settings;
    }
}

/* ---- 三个挂点 ------------------------------------------------ */

@interface AevonSceneWriteGuardHooks : NSObject
@end

@implementation AevonSceneWriteGuardHooks

/* ① 停用原因的统一收口：settings 在这里还是可改的，落地前拦掉。 */
- (void)aevg_deactSet:(unsigned long long)reasons
             onScene:(id)scene
         withSettings:(id)settings
               reason:(id)reason {
    id use = settings;
    @try { use = aevg_fix(settings, scene); } @catch (NSException *e) { use = settings; }
    ((void (*)(id, SEL, unsigned long long, id, id, id))objc_msgSend)(
        self, @selector(aevg_deactSet:onScene:withSettings:reason:), reasons, scene, use, reason);
}

/* ② SBSceneManager 的写前通道（0.3.41 方法表实锤 `v40@0:8@16@24@32`）。 */
- (void)aevg_willUpdate:(id)scene
           withSettings:(id)settings
      transitionContext:(id)context {
    id use = settings;
    @try { use = aevg_fix(settings, scene); } @catch (NSException *e) { use = settings; }
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        self, @selector(aevg_willUpdate:withSettings:transitionContext:), scene, use, context);
}

/* ③ FBScene 自己的写通道（0.2.78 起就挂着，历史日志从未命中；命中就白赚）。 */
- (void)aevg_sceneUpdate:(id)settings
   withTransitionContext:(id)context
              completion:(id)completion {
    id use = settings;
    /* FBScene 这条通道不带 scene 参数 —— self 就是那个场景。 */
    @try { use = aevg_fix(settings, self); } @catch (NSException *e) { use = settings; }
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        self, @selector(aevg_sceneUpdate:withTransitionContext:completion:), use, context, completion);
}

@end

/* ---- 安装（带类型编码自检，签名不符一律不装 = fail-closed） ---- */

static BOOL aevg_install(NSString *className, SEL original, SEL replacement,
                        NSUInteger argCount, NSUInteger objectCount) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        aevg_log([NSString stringWithFormat:@"跳过 %@：类不存在（AevonWriteGuardV342）", className]);
        return NO;
    }
    Method m = class_getInstanceMethod(cls, original);
    if (m == NULL) {
        aevg_log([NSString stringWithFormat:@"跳过 %@ %@：方法不存在（AevonWriteGuardV342）",
                                            className, NSStringFromSelector(original)]);
        return NO;
    }
    const char *enc = method_getTypeEncoding(m);
    if (enc == NULL || enc[0] != 'v') {
        aevg_log([NSString stringWithFormat:@"跳过 %@ %@：返回类型不是 void（%s）（AevonWriteGuardV342）",
                                            className, NSStringFromSelector(original), enc ?: "?");
        return NO;
    }
    NSUInteger colons = 0;
    const char *sel = sel_getName(original);
    for (const char *p = sel; *p != '\0'; p++) { if (*p == ':') { colons += 1; } }
    if (colons != argCount) {
        aevg_log([NSString stringWithFormat:@"跳过 %@ %@：参数个数 %lu ≠ %lu（%s）（AevonWriteGuardV342）",
                                            className, NSStringFromSelector(original),
                                            (unsigned long)colons, (unsigned long)argCount, enc]);
        return NO;
    }

    /* 对象参数个数：编码里 '@' 的个数（含 self）。settings / scene 都必须是对象，
     * 否则我们读到的是标量地址，KVC 一读就是野指针 = 一次注销。 */
    NSUInteger atCount = 0;
    for (const char *p = enc; *p != '\0'; p++) { if (*p == '@') { atCount += 1; } }
    if (atCount < objectCount) {
        aevg_log([NSString stringWithFormat:@"跳过 %@ %@：对象参数 %lu < %lu（%s）（AevonWriteGuardV342）",
                                            className, NSStringFromSelector(original),
                                            (unsigned long)atCount, (unsigned long)objectCount, enc]);
        return NO;
    }

    Method rep = class_getInstanceMethod([AevonSceneWriteGuardHooks class], replacement);
    if (rep == NULL) {
        aevg_log([NSString stringWithFormat:@"跳过 %@：替换方法缺失（AevonWriteGuardV342）", className]);
        return NO;
    }
    /* 把父类实现先复制到目标类，再把目标类的实现换成我们的（与 AevonSwizzle 同款安全步骤）。 */
    if (class_addMethod(cls, original, method_getImplementation(m), method_getTypeEncoding(m))) {
        m = class_getInstanceMethod(cls, original);
        if (m == NULL) { return NO; }
    }
    class_addMethod(cls, replacement, method_getImplementation(rep), method_getTypeEncoding(rep));
    Method mine = class_getInstanceMethod(cls, replacement);
    if (mine == NULL) { return NO; }
    method_exchangeImplementations(m, mine);
    aevg_log([NSString stringWithFormat:@"已安装 %@ %@（%s）（AevonWriteGuardV342）",
                                        className, NSStringFromSelector(original), enc]);
    return YES;
}

void AevonWriteGuardInstall(int enabled) {
    @try {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gBundles = [NSMutableSet set];
            gSceneIDs = [NSMutableSet set];

            if (!enabled) {
                aevg_log(@"拦写关闭（AevonWriteGuardOff342）：本版与 0.3.41 行为一致"
                          "（AevonWriteGuardV342 AevonWriteGuardOffV342）");
                return;
            }

            /* ① 停用原因收口：4 个参数（reasons / scene / settings / reason） */
            BOOL h1 = aevg_install(@"UIApplicationSceneDeactivationManager",
                                   NSSelectorFromString(@"_setDeactivationReasons:onScene:withSettings:reason:"),
                                   @selector(aevg_deactSet:onScene:withSettings:reason:"),
                                   4, 3);
            /* ② SBSceneManager 写前通道：3 个参数（scene / settings / context） */
            BOOL h2 = aevg_install(@"SBSceneManager",
                                   NSSelectorFromString(@"_scene:willUpdateWithSettings:transitionContext:"),
                                   @selector(aevg_willUpdate:withSettings:transitionContext:"),
                                   3, 3);
            /* ③ FBScene 自己的写通道（历史上从未命中，接着挂着不花钱） */
            BOOL h3 = aevg_install(@"FBScene",
                                   NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"),
                                   @selector(aevg_sceneUpdate:withTransitionContext:completion:"),
                                   3, 4);
            BOOL any = (h1 || h2 || h3);

            gInstalled = any;
            if (!any) {
                aevg_log(@"三个挂点全部不可用 → 不拦写，行为回退到 0.3.41"
                          "（AevonWriteGuardV342 AevonWriteGuardPassV342）");
            } else {
                aevg_log(@"拦写就绪：承载中场景的 foreground 回收会在落地前被改成 YES"
                          "（AevonWriteGuardV342）");
            }
        });
    } @catch (NSException *exception) {
        gInstalled = NO;
        aevg_log([NSString stringWithFormat:@"安装异常，已放弃拦写：%@（AevonWriteGuardV342）",
                                            exception.name ?: @"?"]);
    }
}

NSInteger AevonWriteGuardRewriteCount(void) {
    return gRewrites;
}
