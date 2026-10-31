/* AevonSnapProbe.m —— V0.3.36（AevonSnapProbeV336）
 *
 * K2-A 第一步：**只读探针**。本文件不产生任何写操作，不改任何既有行为。
 *
 * 为什么需要它
 * ------------
 * Aevon(107) 把「画面由虚变实」的病灶钉死在遮盖物的来源上：
 *   · `AevonWindowView.swift:1712` 用自抓 `drawHierarchy(in:afterScreenUpdates:NO)`
 *     去抓远程表面，场景降级那一拍抓到的就是半糊的图；
 *   · 同一份日志第 634 行自证：`缓存帧连续 6 次被判模糊 → 清晰度 1680`。
 * 而 TrollOpen / Mango / ScreenCore 三家全都有系统挂起快照
 * （`saveSuspendSnapshot:` / `saveSuspendSnapshot:forSceneHandle:` /
 *   `saveSnapshotForSceneHandle:context:completion:`）—— 清晰度与拍摄时机由系统保证，
 * 不需要我们再判「什么时候够清晰」。
 *
 * 但那些名字是从 strings 里读出来的，**读得出名字 ≠ 知道谁是宿主、参数怎么排、
 * 返回值是什么、有没有读取侧**。0.3.26 就吃过这个亏：
 * 猜的两个谓词类都不存在（矩阵打出「谓词=无/无」），断言成了空断言，白烧一个版本。
 *
 * 所以本版只做一件事：**在真机上把真实接口 dump 回来**。
 *
 * 探针要回答的四个问题
 * --------------------
 *  Q1 写入侧：谁能「让系统存一张快照」？宿主类是谁？参数顺序？
 *  Q2 读取侧：存完之后怎么把它变成 UIImage？有没有直接拿图的选择子？
 *  Q3 句柄：`saveSuspendSnapshot:forSceneHandle:` 要 handle —— 从我们手里的
 *           FBScene 能不能反查出 `SBDeviceApplicationSceneHandle`？
 *  Q4 兜底：SpringBoard 的切换器快照缓存 `SBAppSwitcherSnapshotImageCache`
 *           是不是更好的一条路（它缓存的就是系统拍的清晰快照）。
 *
 * 纪律
 * ----
 *  · 全程 `@try/@catch`：Swift 抓不到 NSException，未知选择子直接 SIGABRT。
 *  · 全程只读：不调用任何名字里带 save/set/create 的方法；ivar 只 `object_getIvar`。
 *  · 每个进程只跑一次（`gRan`）；总闸 `AevonSnapProbeOff336` 写 true 即整段不跑。
 *  · 方法名过滤成「含 snapshot」再打，避免单行过长被日志截断。
 *  · typeEncoding 必须打 —— 落地方案要靠它决定参数怎么摆。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "AevonSnapProbe.h"

/* 由 Swift 侧 @_cdecl("AevonSnapProbeLog") 实现：统一走 AevonLog，带标记串。 */
extern void AevonSnapProbeLog(const char *utf8Detail);

/* ⛔ 标记必须整串纯 ASCII 且落在 __cstring 里：注释和 @"中文…" 都不进二进制。
 * audit_markers.py 只认整串 ASCII 的字面量，所以一条一个声明。 */
__attribute__((used)) static const char AevonSnapProbeV336[] = "AevonSnapProbeV336";
__attribute__((used)) static const char AevonSnapCensusV336[] = "AevonSnapCensusV336";
__attribute__((used)) static const char AevonSnapIvarV336[] = "AevonSnapIvarV336";
__attribute__((used)) static const char AevonSnapSelV336[] = "AevonSnapSelV336";
__attribute__((used)) static const char AevonSnapNoWriteV336[] = "AevonSnapNoWriteV336";

static BOOL gRan = NO;
static BOOL gOff = NO;
static BOOL gConfigLoaded = NO;

static void aevs_ensure_config(void) {
    if (gConfigLoaded) { return; }
    gConfigLoaded = YES;
    id off = [[NSUserDefaults standardUserDefaults] objectForKey:@"AevonSnapProbeOff336"];
    gOff = (off != nil) ? [off boolValue] : NO;
}

static SEL aevs_sel(NSString *name) { return NSSelectorFromString(name); }

static BOOL aevs_responds(id obj, NSString *sel) {
    if (obj == nil) { return NO; }
    @try {
        return [obj respondsToSelector:aevs_sel(sel)];
    } @catch (NSException *e) {
        return NO;
    }
}

static void aevs_log(NSString *line) {
    if (line == nil) { return; }
    @try {
        AevonSnapProbeLog(line.UTF8String);
    } @catch (NSException *e) {
        /* 日志失败绝不影响任何路径 */
    }
}

/* ---- 一、方法普查：只打含 snapshot 的，附 typeEncoding ---- */

/// 返回 "总方法数/命中数"，命中项拼成 `名字(签名)|…`。
static NSString *aevs_snapshot_methods(Class cls, NSUInteger limit) {
    if (cls == nil) { return @"-"; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSUInteger total = (NSUInteger)n;
    if (ms != NULL) {
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (nm == NULL) { continue; }
            NSString *name = [NSString stringWithUTF8String:nm];
            if (name == nil) { continue; }
            /* 不区分大小写找 snapshot */
            if ([name rangeOfString:@"snapshot" options:NSCaseInsensitiveSearch].location
                == NSNotFound) { continue; }
            if (out.count >= limit) { break; }
            const char *enc = method_getTypeEncoding(ms[i]);
            NSString *sig = (enc != NULL) ? [NSString stringWithUTF8String:enc] : @"?";
            [out addObject:[NSString stringWithFormat:@"%@(%@)", name, sig]];
        }
        free(ms);
    }
    NSString *body = out.count > 0 ? [out componentsJoinedByString:@"|"] : @"无";
    return [NSString stringWithFormat:@"总%lu/命中%lu %@",
            (unsigned long)total, (unsigned long)out.count, body];
}

/// 类方法（元类）上的 snapshot 方法。
static NSString *aevs_snapshot_class_methods(Class cls, NSUInteger limit) {
    if (cls == nil) { return @"-"; }
    Class meta = object_getClass((id)cls);
    if (meta == nil) { return @"-"; }
    return aevs_snapshot_methods(meta, limit);
}

/// 沿继承链把带 snapshot 的方法全打一遍（子类 + 父类各一行）。
static void aevs_dump_chain(NSString *tag, Class cls, NSUInteger limit) {
    Class cur = cls;
    int depth = 0;
    while (cur != Nil && depth < 4) {
        NSString *line = [NSString stringWithFormat:
                          @"%@ %@ 实例方法：%@（%@）",
                          tag, NSStringFromClass(cur),
                          aevs_snapshot_methods(cur, limit),
                          [NSString stringWithUTF8String:AevonSnapCensusV336]];
        aevs_log(line);
        cur = class_getSuperclass(cur);
        depth++;
    }
}

/* ---- 二、ivar 普查：只读，只碰对象类型 ---- */

static void aevs_dump_ivars(NSString *tag, id obj) {
    if (obj == nil) { return; }
    Class cls = object_getClass(obj);
    if (cls == nil) { return; }
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(cls, &n);
    if (ivars == NULL) { return; }
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = ivar_getName(ivars[i]);
        const char *enc = ivar_getTypeEncoding(ivars[i]);
        if (nm == NULL || enc == NULL) { continue; }
        NSString *name = [NSString stringWithUTF8String:nm];
        if (name == nil) { continue; }
        NSString *encStr = [NSString stringWithUTF8String:enc];
        if (encStr == nil) { continue; }

        BOOL nameHit = ([name rangeOfString:@"snapshot" options:NSCaseInsensitiveSearch].location
                        != NSNotFound);
        BOOL typeHit = ([encStr rangeOfString:@"Snapshot" options:NSCaseInsensitiveSearch].location
                        != NSNotFound);
        if (!nameHit && !typeHit) { continue; }

        /* ⛔ 绝不读 ivar 的值。
         *
         * `object_getIvar` 有两个 @try 抓不住的崩溃面：
         *   · 非对象类型（标量/结构体）直接 SIGSEGV；
         *   · `__unsafe_unretained` 且已释放 → 野指针，随后 `[iv class]` 也崩。
         * 本探针跑在 SpringBoard 里，崩一次就是一次注销/respring —— 代价远大于
         * 「知道快照缓存挂在哪个 ivar」这点信息收益。所以只记名字与类型编码。
         * 真要判「这个 ivar 有没有值」，等 0.3.37 拿到真名后用 KVC 走正规通道读。 */
        [hits addObject:[NSString stringWithFormat:@"%@:%@", name, encStr]];
    }
    free(ivars);
    NSString *body = hits.count > 0 ? [hits componentsJoinedByString:@"|"] : @"无";
    aevs_log([NSString stringWithFormat:@"%@ ivar 共%u 项，命中：%@（%@）",
              tag, n, body, [NSString stringWithUTF8String:AevonSnapIvarV336]]);
}

/* ---- 三、关键选择子矩阵：respondsToSelector + typeEncoding 实证 ---- */

/// 对某个实例/类，逐个名字判存在并取签名。签名缺失说明方法不存在（或不是 ObjC 方法）。
static void aevs_probe_selectors(NSString *tag, id target, NSArray<NSString *> *names) {
    if (target == nil || names.count == 0) { return; }
    Class cls = object_getClass(target);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in names) {
        SEL sel = aevs_sel(name);
        BOOL ok = NO;
        @try {
            ok = [target respondsToSelector:sel];
        } @catch (NSException *e) {
            ok = NO;
        }
        if (!ok) {
            [out addObject:[NSString stringWithFormat:@"%@=无", name]];
            continue;
        }
        const char *enc = NULL;
        @try {
            Method m = class_getInstanceMethod(cls, sel);
            if (m != NULL) { enc = method_getTypeEncoding(m); }
        } @catch (NSException *e) {
            enc = NULL;
        }
        NSString *sig = (enc != NULL) ? [NSString stringWithUTF8String:enc] : @"?";
        [out addObject:[NSString stringWithFormat:@"%@=%@", name, sig]];
    }
    aevs_log([NSString stringWithFormat:@"%@ 选择子：%@（%@）",
              tag, [out componentsJoinedByString:@" | "],
              [NSString stringWithUTF8String:AevonSnapSelV336]]);
}

/* ---- 四、从 FBScene 反查 SBDeviceApplicationSceneHandle ---- */

static id aevs_find_handle(id scene) {
    if (scene == nil) { return nil; }
    for (NSString *name in @[@"handle", @"sceneHandle", @"_sceneHandle", @"_handle"]) {
        if (!aevs_responds(scene, name)) { continue; }
        @try {
            id h = ((id (*)(id, SEL))objc_msgSend)(scene, aevs_sel(name));
            if (h != nil) { return h; }
        } @catch (NSException *e) {
            /* 继续试下一个名字 */
        }
    }
    return nil;
}

/* ---- 五、主流程 ---- */

int AevonSnapProbeRun(void *scenePtr) {
    aevs_ensure_config();
    if (gOff) { return 0; }
    if (gRan) { return 0; }
    if (scenePtr == NULL) { return 0; }

    id scene = (__bridge id)scenePtr;
    if (scene == nil) { return 0; }
    gRan = YES;

    aevs_log([NSString stringWithFormat:@"开始只读取证，不产生任何写操作（%@ %@）",
              [NSString stringWithUTF8String:AevonSnapProbeV336],
              [NSString stringWithUTF8String:AevonSnapNoWriteV336]]);

    /* Q1/Q2/Q4：候选类是否存在。存在才值得往下 dump。 */
    NSArray<NSString *> *classNames = @[
        @"FBScene",
        @"FBSceneSnapshot",
        @"FBSceneSnapshotContext",
        @"FBSSceneSnapshotContext",
        @"FBSSceneSnapshotRequest",
        @"SBSceneSnapshotRequestHandler",
        @"SBDeviceApplicationSceneHandle",
        @"SBSceneManager",
        @"SBAppSwitcherSnapshotImageCache",
        @"SBAppSwitcherSnapshotCacheEntry",
    ];
    NSMutableArray<NSString *> *exist = [NSMutableArray array];
    for (NSString *name in classNames) {
        Class c = NSClassFromString(name);
        [exist addObject:[NSString stringWithFormat:@"%@=%@", name, c ? @"有" : @"无"]];
    }
    aevs_log([NSString stringWithFormat:@"类存在：%@（%@）",
              [exist componentsJoinedByString:@" "],
              [NSString stringWithUTF8String:AevonSnapCensusV336]]);

    /* 实场景的真类（可能是 FBScene 的子类，名字很重要）。 */
    aevs_log([NSString stringWithFormat:@"实场景类=%@（%@）",
              NSStringFromClass([scene class]),
              [NSString stringWithUTF8String:AevonSnapProbeV336]]);

    /* Q1：写入侧候选 —— 这几个类的 snapshot 方法全 dump（含继承链）。 */
    for (NSString *name in @[@"FBScene", @"FBSceneSnapshot", @"FBSSceneSnapshotContext",
                             @"SBSceneSnapshotRequestHandler", @"SBDeviceApplicationSceneHandle",
                             @"SBSceneManager", @"SBAppSwitcherSnapshotImageCache"]) {
        Class c = NSClassFromString(name);
        if (c == Nil) { continue; }
        aevs_dump_chain(name, c, 24);
        /* 类方法（例如 +[SBSceneManager someSharedThing]）也看一眼。 */
        NSString *cm = aevs_snapshot_class_methods(c, 12);
        if (![cm hasSuffix:@"命中0 无"]) {
            aevs_log([NSString stringWithFormat:@"%@ 类方法：%@（%@）",
                      name, cm, [NSString stringWithUTF8String:AevonSnapCensusV336]]);
        }
    }

    /* Q3：从 scene 反查 handle，并 dump handle 的 snapshot 方法。 */
    id handle = aevs_find_handle(scene);
    if (handle != nil) {
        NSString *hcls = NSStringFromClass([handle class]);
        aevs_log([NSString stringWithFormat:@"反查句柄=成功 类=%@（%@）",
                  hcls, [NSString stringWithUTF8String:AevonSnapIvarV336]]);
        aevs_log([NSString stringWithFormat:@"句柄 snapshot 方法：%@（%@）",
                  aevs_snapshot_methods([handle class], 24),
                  [NSString stringWithUTF8String:AevonSnapCensusV336]]);
        aevs_probe_selectors(@"句柄",
                             handle,
                             @[@"saveSuspendSnapshot:",
                               @"saveSuspendSnapshot:forSceneHandle:",
                               @"saveSnapshotForSceneHandle:context:completion:",
                               @"snapshotView",
                               @"_snapshotView",
                               @"_snapshotImage"]);
    } else {
        aevs_log([NSString stringWithFormat:@"反查句柄=失败（handle/sceneHandle/_sceneHandle/_handle 全无）（%@）",
                  [NSString stringWithUTF8String:AevonSnapIvarV336]]);
        /* 退一步：manager 侧能不能按 identity 换 handle —— 这条 0.3.37 可能要用。 */
        aevs_probe_selectors(@"SBSceneManager 类方法",
                             (id)NSClassFromString(@"SBSceneManager"),
                             @[@"existingSceneHandleForSceneIdentity:",
                               @"sceneHandleForSceneIdentifier:",
                               @"sceneHandleForScene:"]);
    }

    /* Q2：scene 实例上到底有没有「直接拿快照」的选择子。签名是关键 —— 有签名才敢调。 */
    aevs_probe_selectors(@"实场景",
                         scene,
                         @[@"snapshotContext:",
                           @"createSnapshotWithContext:completion:",
                           @"snapshotWithContext:completion:",
                           @"snapshot",
                           @"snapshotView",
                           @"_snapshotView",
                           @"_snapshotImage",
                           @"handle",
                           @"sceneHandle",
                           @"_sceneHandle"]);

    /* 方法名兜底：万一上面的名字全错，这里能看见真名。 */
    aevs_log([NSString stringWithFormat:@"实场景 snapshot 方法：%@（%@）",
              aevs_snapshot_methods([scene class], 32),
              [NSString stringWithUTF8String:AevonSnapCensusV336]]);

    /* ivar 兜底：有些实现把快照直接存在 ivar 里（_snapshotView / _snapshotImage）。 */
    aevs_dump_ivars(@"实场景", scene);
    if (handle != nil) { aevs_dump_ivars(@"句柄", handle); }

    aevs_log([NSString stringWithFormat:@"取证结束（%@）",
              [NSString stringWithUTF8String:AevonSnapProbeV336]]);
    return 1;
}
