/* AevonSceneCensus.m —— V0.3.41（AevonSceneCensusV341）
 *
 * C 路线第一步：SpringBoard 场景承载通路的**只读普查**。
 * 本文件不产生任何写操作，不改任何既有行为（CI 断言锁死「零写」）。
 *
 * 这一版要回答的三个问题
 * ----------------------
 *  Q1 建/取「App 场景句柄」的真实方法名是什么？
 *     —— `SBDeviceApplicationSceneHandle` / `_SBDeviceApplicationSceneHandle` /
 *        `SBApplicationSceneHandle` / `SBSceneManager` 的**完整方法表**（含 typeEncoding）。
 *        0.2.28~0.2.80 的教训：场景用 `createSceneWithDefinition:initialParameters:`
 *        建得出来（MangoHello 串表里也是同一个选择子），但 App 端永远不接
 *        （连接取证恒为 `client=FBWorkspace clientPort=nil`）。Mango 与我们的唯一差别
 *        是它多了一层 `_SBDeviceApplicationSceneHandle`。那一层的构造方法名，
 *        只能从方法表里读，**不能猜**（在 SB 里猜选择子 = 一次注销）。
 *
 *  Q2 掉画那一刻，现场到底少的是什么？
 *     —— 回桌面期间按拍采样：`fg` / `deactivationReasons` / `contentState` /
 *        `layerManager.layers` / `layerCls` / `clientProcess` / `uiPresentationManager`。
 *        0.3.40 只证明了「断言还在，cs 照样 2→0」；是「层被清空」还是「场景被挂起」，
 *        目前没有一行现场数据。
 *
 *  Q3 `saveSuspendSnapshot:forSceneHandle:` 的句柄到底能不能从 FBScene 反查？
 *     —— 类方法 / 实例方法两条路都试（0.3.36 探针只试了类方法，全 miss）。
 *
 * 纪律
 * ----
 *  · 全程 `@try/@catch`：Swift 抓不到 NSException，未知选择子直接 SIGABRT。
 *  · **零写**：不出现 updateSettings / setForeground / setSuspended / destroyScene /
 *    createScene 调用。只读 KVC、respondsToSelector、class_copyMethodList。
 *  · 标量一律走 KVC（装箱成 NSNumber），**绝不 `object_getIvar`** ——
 *    对非对象类型 SIGSEGV、对已释放的 __unsafe_unretained 是野指针，
 *    @try 都抓不住，而它跑在 SpringBoard 里 = 一次注销（0.3.36 铁律）。
 *  · 每进程只跑一次（`gRan`）；总闸 `AevonSceneCensusOff341` = true 时整段不跑。
 *  · 总行数上限 4000：方法表再大也不许把日志刷爆。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdio.h>
#import <unistd.h>

#import "AevonSceneCensus.h"

/* 由 Swift 侧 @_cdecl("AevonSceneCensusLog") 实现：统一走 AevonLog。 */
extern void AevonSceneCensusLog(const char *utf8Detail);

/* ⛔ 标记必须整串纯 ASCII 且落在 __cstring 里：注释和 @"中文…" 都不进二进制。
 * audit_markers.py 只认整串 ASCII 字面量，所以一条一个声明。 */
__attribute__((used)) static const char AevonSceneCensusV341[] = "AevonSceneCensusV341";
__attribute__((used)) static const char AevonCensusNoWriteV341[] = "AevonCensusNoWriteV341";
__attribute__((used)) static const char AevonCensusSampleV341[] = "AevonCensusSampleV341";
__attribute__((used)) static const char AevonCensusHandleV341[] = "AevonCensusHandleV341";

static BOOL gRan = NO;
static BOOL gOff = NO;
static BOOL gConfigLoaded = NO;
static int gLines = 0;
static const int kLineCap = 3000;

static void aevc_ensure_config(void) {
    if (gConfigLoaded) { return; }
    gConfigLoaded = YES;
    id off = [[NSUserDefaults standardUserDefaults] objectForKey:@"AevonSceneCensusOff341"];
    gOff = (off != nil) ? [off boolValue] : NO;
}

static void aevc_log(NSString *line) {
    if (line == nil) { return; }
    if (gLines >= kLineCap) { return; }
    gLines += 1;
    @try {
        AevonSceneCensusLog(line.UTF8String);
    } @catch (NSException *exception) {
        /* 日志失败绝不影响任何路径 */
    }
}

/* ---- 只读工具（全部 @try 包裹，绝不抛到系统） ---------------- */

static SEL aevc_sel(NSString *name) { return NSSelectorFromString(name); }

static BOOL aevc_responds(id obj, NSString *selName) {
    if (obj == nil) { return NO; }
    @try {
        return [obj respondsToSelector:aevc_sel(selName)];
    } @catch (NSException *exception) {
        return NO;
    }
}

/// 无参、返回 id 的选择子（只用于已知返回对象的读侧：identifier / settings /
/// layerManager / clientProcess / uiPresentationManager）。
static id aevc_id0(id obj, NSString *selName) {
    if (obj == nil) { return nil; }
    @try {
        if (![obj respondsToSelector:aevc_sel(selName)]) { return nil; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return fn(obj, aevc_sel(selName));
    } @catch (NSException *exception) {
        return nil;
    }
}

/// KVC 读任意字段（标量会被装箱成 NSNumber/NSValue）—— **标量只走这条路**。
static NSString *aevc_kvc(id obj, NSString *key) {
    if (obj == nil || key == nil) { return @"-"; }
    @try {
        id v = [obj valueForKey:key];
        if (v == nil) { return @"nil"; }
        return [NSString stringWithFormat:@"%@", v];
    } @catch (NSException *exception) {
        return @"(无)";
    }
}

static NSString *aevc_className(id obj) {
    if (obj == nil) { return @"nil"; }
    @try {
        return NSStringFromClass([obj class]) ?: @"?";
    } @catch (NSException *exception) {
        return @"(抛)";
    }
}

/// layers 数组里前三个层的类名 —— 判断「远程层还在不在」的直接证据。
static NSString *aevc_layerClasses(id scene) {
    @try {
        id lm = aevc_id0(scene, @"layerManager");
        if (lm == nil) { return @"(无layerManager)"; }
        id layers = aevc_id0(lm, @"layers");
        if (![layers isKindOfClass:[NSArray class]]) { return @"(非数组)"; }
        NSArray *arr = (NSArray *)layers;
        NSMutableArray *names = [NSMutableArray array];
        NSUInteger limit = MIN((NSUInteger)3, arr.count);
        for (NSUInteger i = 0; i < limit; i++) {
            [names addObject:aevc_className(arr[i])];
        }
        return [NSString stringWithFormat:@"[%@] 共%lu", [names componentsJoinedByString:@","],
                                          (unsigned long)arr.count];
    } @catch (NSException *exception) {
        return @"(抛)";
    }
}

/* ---- 一、方法表普查 ------------------------------------------ */

/// 名字里出现任一关键词才打（过滤档用）。名字先小写化再匹配。
static BOOL aevc_interest(const char *name) {
    if (name == NULL) { return NO; }
    static const char *keys[] = {
        "scene", "handle", "layer", "workspace", "create", "init", "new",
        "attach", "host", "foreground", "background", "suspend", "present",
        "application", "register", "destroy", "invalidate", "process", "pid"
    };
    char low[256];
    size_t n = strlen(name);
    if (n >= sizeof(low)) { n = sizeof(low) - 1; }
    for (size_t i = 0; i < n; i++) {
        char c = name[i];
        low[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
    }
    low[n] = '\0';
    for (size_t k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
        if (strstr(low, keys[k]) != NULL) { return YES; }
    }
    return NO;
}

static void aevc_dump_list(Class cls, BOOL isMeta, BOOL full) {
    if (cls == Nil) { return; }
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    if (list == NULL) { return; }
    int printed = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = sel_getName(method_getName(list[i]));
        if (nm == NULL) { continue; }
        if (!full && !aevc_interest(nm)) { continue; }
        const char *enc = method_getTypeEncoding(list[i]);
        char encBuf[96];
        if (enc == NULL) {
            snprintf(encBuf, sizeof(encBuf), "?");
        } else {
            size_t len = strlen(enc);
            if (len >= sizeof(encBuf)) { len = sizeof(encBuf) - 1; }
            memcpy(encBuf, enc, len);
            encBuf[len] = '\0';
        }
        aevc_log([NSString stringWithFormat:@"%s %s :: %s", isMeta ? "+" : "-", nm, encBuf]);
        printed += 1;
        if (gLines >= kLineCap) { break; }
    }
    free(list);
    aevc_log([NSString stringWithFormat:@"  ^ 本层共 %u 个方法，打印 %d 个%@",
                                        count, printed, full ? @"（全量）" : @"（关键词过滤）"]);
}

/// 打一个类：自身 + 元类（类方法）+ 直接父类一层（很多初始化方法挂在父类上）。
static void aevc_dump_class(const char *clsName, BOOL full) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:clsName]);
    if (cls == Nil) {
        aevc_log([NSString stringWithFormat:@"==== %s : 类不存在 ====", clsName]);
        return;
    }
    aevc_log([NSString stringWithFormat:@"==== %s : 存在 ====", clsName]);
    aevc_dump_list(cls, NO, full);
    aevc_dump_list(object_getClass(cls), YES, full);
    Class superCls = class_getSuperclass(cls);
    if (superCls != Nil && superCls != [NSObject class]) {
        aevc_log([NSString stringWithFormat:@"---- 父类 %@ ----",
                                            NSStringFromClass(superCls) ?: @"?"]);
        aevc_dump_list(superCls, NO, full);
    }
}

/* ---- 二、句柄反查（Q3） -------------------------------------- */

/// 从 FBScene 反查 SBDeviceApplicationSceneHandle：类方法 / 实例方法两条路都试。
/// 返回一行判读串，例：`inst:1 cls:0 identity:1`。
static NSString *aevc_handle_probe(id scene) {
    @try {
        id sid = aevc_id0(scene, @"identifier");
        if (sid == nil) { return @"无identifier"; }
        Class providerCls = NSClassFromString(@"SBSceneIdentityProvider");
        SEL idSel = aevc_sel(@"identityForIdentifier:");
        id identity = nil;
        if (providerCls != Nil && [providerCls respondsToSelector:idSel]) {
            id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            identity = fn((id)providerCls, idSel, sid);
        }
        Class mgrCls = NSClassFromString(@"SBSceneManager");
        if (mgrCls == Nil) { return @"无SBSceneManager"; }
        SEL hSel = aevc_sel(@"existingSceneHandleForSceneIdentity:");
        id (*fn2)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        int clsOK = 0, instOK = 0, instHave = 0;
        if (identity != nil) {
            if ([mgrCls respondsToSelector:hSel]) {
                id h = fn2((id)mgrCls, hSel, identity);
                clsOK = (h != nil) ? 1 : 0;
            }
            id mgr = aevc_id0((id)mgrCls, @"sharedInstance");
            if (mgr == nil) { mgr = aevc_id0((id)mgrCls, @"sharedManager"); }
            if (mgr != nil) {
                instHave = 1;
                if ([mgr respondsToSelector:hSel]) {
                    id h = fn2(mgr, hSel, identity);
                    instOK = (h != nil) ? 1 : 0;
                }
            }
        }
        return [NSString stringWithFormat:@"identity=%@ cls=%d instMgr=%d inst=%d",
                                          identity ? @"有" : @"无", clsOK, instHave, instOK];
    } @catch (NSException *exception) {
        return @"(抛)";
    }
}

/* ---- 三、现场采样（Q2） -------------------------------------- */

void AevonSceneCensusSample(void *scenePtr, const char *tag) {
    aevc_ensure_config();
    if (gOff) { return; }
    @try {
        id scene = (__bridge id)scenePtr;
        if (scene == nil) { return; }
        id settings = aevc_id0(scene, @"settings");
        NSString *tagStr = (tag != NULL) ? [NSString stringWithUTF8String:tag] : @"?";
        NSMutableString *line = [NSMutableString stringWithFormat:@"采样 tag=%@", tagStr ?: @"?"];
        [line appendFormat:@" id=%@", aevc_id0(scene, @"identifier") ?: @"?"];
        [line appendFormat:@" fg=%@", aevc_kvc(settings, @"foreground")];
        [line appendFormat:@" dr=%@", aevc_kvc(settings, @"deactivationReasons")];
        [line appendFormat:@" cs=%@", aevc_kvc(scene, @"contentState")];
        [line appendFormat:@" active=%@", aevc_kvc(scene, @"isActive")];
        [line appendFormat:@" layerCls=%@", aevc_layerClasses(scene)];
        [line appendFormat:@" client=%@", aevc_className(aevc_id0(scene, @"clientProcess"))];
        [line appendFormat:@" pm=%@", aevc_className(aevc_id0(scene, @"uiPresentationManager"))];
        [line appendFormat:@" r_setSusp=%d r_susp=%d",
            aevc_responds(scene, @"setSuspended:") ? 1 : 0,
            aevc_responds(scene, @"suspend") ? 1 : 0];
        [line appendFormat:@" handle[%@]", aevc_handle_probe(scene)];
        aevc_log(line);
    } @catch (NSException *exception) {
        NSString *tagStr = (tag != NULL) ? [NSString stringWithUTF8String:tag] : @"?";
        aevc_log([NSString stringWithFormat:@"采样异常 tag=%@ : %@",
                                            tagStr ?: @"?", exception.name ?: @"?"]);
    }
}

/* ---- 四、一次性普查入口 -------------------------------------- */

static void aevc_run_body(void *scene) {
    aevc_log([NSString stringWithFormat:@"开局 pid=%d （AevonSceneCensusV341 AevonCensusNoWriteV341）",
                                        (int)getpid()]);

    /* 4.1 候选类的存在性 —— 一行看完哪些类在这个系统上有。 */
    NSArray<NSString *> *names = @[
        @"FBScene", @"FBWorkspace", @"FBSceneManager",
        @"FBSMutableSceneDefinition", @"FBSSceneDefinition",
        @"FBSSceneLayerManager", @"FBSceneLayerManager",
        @"SBSceneManager", @"SBSceneIdentityProvider",
        @"SBDeviceApplicationSceneHandle", @"_SBDeviceApplicationSceneHandle",
        @"SBApplicationSceneHandle", @"SBApplicationSceneViewController",
        @"SBDeviceApplicationSceneViewController", @"SBApplication",
        @"SBApplicationSceneRequest"
    ];
    NSMutableArray<NSString *> *exist = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *n in names) {
        if (NSClassFromString(n) != Nil) { [exist addObject:n]; } else { [missing addObject:n]; }
    }
    aevc_log([NSString stringWithFormat:@"类存在：%@", [exist componentsJoinedByString:@","]]);
    aevc_log([NSString stringWithFormat:@"类缺席：%@", [missing componentsJoinedByString:@","]]);

    /* 4.2 方法表。full=YES 的四个类是全量：句柄工厂与场景本体的方法名必须看全。 */
    /* ⛔ 全量只给三个「句柄类」：它们是 C 路线唯一缺的那一跳（场景 → App 场景句柄）。
     * 其余一律关键词过滤 —— 日志是同步写盘的（AevonLog 直接 FileHandle.write），
     * 一次开窗灌几千行会把开窗拖慢半秒以上。 */
    aevc_dump_class("SBDeviceApplicationSceneHandle", YES);
    aevc_dump_class("_SBDeviceApplicationSceneHandle", YES);
    aevc_dump_class("SBApplicationSceneHandle", YES);
    aevc_dump_class("SBSceneManager", NO);
    aevc_dump_class("FBScene", NO);
    aevc_dump_class("FBWorkspace", NO);
    aevc_dump_class("FBSMutableSceneDefinition", NO);
    aevc_dump_class("FBSSceneDefinition", NO);
    aevc_dump_class("FBSSceneLayerManager", NO);
    aevc_dump_class("FBSceneLayerManager", NO);
    aevc_dump_class("SBSceneIdentityProvider", NO);
    aevc_dump_class("SBApplication", NO);
    aevc_dump_class("SBApplicationSceneViewController", NO);
    aevc_dump_class("SBDeviceApplicationSceneViewController", NO);
    aevc_dump_class("SBApplicationSceneRequest", NO);

    /* 4.3 现场：这一刻场景是什么状态（开窗后第一拍）。 */
    AevonSceneCensusSample(scene, "普查首采样");

    aevc_log([NSString stringWithFormat:@"收尾 共 %d 行（AevonCensusSampleV341 AevonCensusHandleV341）",
                                        gLines]);
}

int AevonSceneCensusRun(void *scene) {
    aevc_ensure_config();
    if (gOff) { return 0; }
    if (gRan) { return 0; }
    if (scene == NULL) { return 0; }
    gRan = YES;
    @try {
        aevc_run_body(scene);
    } @catch (NSException *exception) {
        aevc_log([NSString stringWithFormat:@"普查异常：%@", exception.name ?: @"?"]);
    }
    return 1;
}
