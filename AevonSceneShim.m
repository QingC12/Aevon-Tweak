/* CI 标记（V0.0.75）：安全方法调用垫片必须编进主 dylib（
 * Aevon(67) 自动注销的根治点：BOOL 返回值被 perform 当成对象指针）。 */
__attribute__((used)) static const char AevonSceneSafeCallV75Marker[] = "AevonSceneSafeCallV75";

#import "AevonSceneShim.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <strings.h>

/// 场景尺寸改写（V0.0.55）。全部私有 API，全部走运行时探测 + 异常保护。

static BOOL AevonObjectHasSetFrame(id object) {
    if (object == nil) { return NO; }
    return [object respondsToSelector:NSSelectorFromString(@"setFrame:")];
}

static BOOL AevonObjectHasFrame(id object) {
    if (object == nil) { return NO; }
    return [object respondsToSelector:NSSelectorFromString(@"frame")];
}

static CGRect AevonObjectFrame(id object) {
    if (!AevonObjectHasFrame(object)) { return CGRectZero; }
    SEL sel = NSSelectorFromString(@"frame");
    CGRect (*fn)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
    return fn(object, sel);
}

static void AevonObjectSetFrame(id object, CGRect frame) {
    SEL sel = NSSelectorFromString(@"setFrame:");
    void (*fn)(id, SEL, CGRect) = (void (*)(id, SEL, CGRect))objc_msgSend;
    fn(object, sel, frame);
}

BOOL AevonSettingsSetFrame(id settings, CGRect frame) {
    if (settings == nil) { return NO; }
    @try {
        if (!AevonObjectHasSetFrame(settings)) { return NO; }
        AevonObjectSetFrame(settings, frame);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

BOOL AevonSceneFrameSupported(id scene) {
    @try {
        if (scene == nil) { return NO; }
        SEL sel = NSSelectorFromString(@"settings");
        if (![scene respondsToSelector:sel]) { return NO; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id settings = fn(scene, sel);
        return AevonObjectHasFrame(settings) || AevonObjectHasSetFrame(settings);
    } @catch (NSException *exception) {
        return NO;
    }
}

CGSize AevonSceneFrameSize(id scene) {
    @try {
        if (scene == nil) { return CGSizeZero; }
        SEL sel = NSSelectorFromString(@"settings");
        if (![scene respondsToSelector:sel]) { return CGSizeZero; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id settings = fn(scene, sel);
        CGRect frame = AevonObjectFrame(settings);
        return frame.size;
    } @catch (NSException *exception) {
        return CGSizeZero;
    }
}

BOOL AevonSceneSetFrameSize(id scene, CGSize size) {
    if (scene == nil || size.width < 1.0 || size.height < 1.0) { return NO; }
    @try {
        SEL settingsSel = NSSelectorFromString(@"settings");
        if (![scene respondsToSelector:settingsSel]) { return NO; }
        id (*getSettings)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id settings = getSettings(scene, settingsSel);
        if (settings == nil) { return NO; }

        // mutableCopy 会按真实子类（FBSMutableSceneSettings / SBMutableApplicationSceneSettings）
        // 返回可变副本；直接改不可变对象会抛异常。
        SEL copySel = NSSelectorFromString(@"mutableCopy");
        if (![settings respondsToSelector:copySel]) { return NO; }
        id (*doCopy)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id mutable = doCopy(settings, copySel);
        if (mutable == nil) { return NO; }

        if (!AevonSettingsSetFrame(mutable, CGRectMake(0, 0, size.width, size.height))) {
            return NO;
        }

        SEL updateSel = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        SEL updateShortSel = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:updateSel]) {
            void (*fn)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))objc_msgSend;
            fn(scene, updateSel, mutable, nil, nil);
        } else if ([scene respondsToSelector:updateShortSel]) {
            void (*fn)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
            fn(scene, updateShortSel, mutable, nil);
        } else {
            return NO;
        }

        // 校验：系统读回来的尺寸是否就是我们要的（±1pt 容差）
        CGSize now = AevonSceneFrameSize(scene);
        if (now.width < 1.0) { return NO; }
        return fabs(now.width - size.width) <= 1.0 && fabs(now.height - size.height) <= 1.0;
    } @catch (NSException *exception) {
        return NO;
    }
}

/* ═══════════════════════════════════════════════════════════════════
 * V0.0.59（AevonTrueResizeV59）：帧 + displayConfiguration 一起下发。
 *
 * V0.0.55 只写 frame 的结论（AevonSceneFrameSize 真机日志）：
 *   场景 267×458 写入成功，但那只是渲染视口 —— App 的 UIWindow 仍 430×932，
 *   内容按整屏排版后视口只露左 62%（字变大、右侧工具栏消失）。
 *
 * Mango 的逆向实证（analysis/mango/README-analysis.md §二）给了缺失的那一块：
 *   `mangoDisplayConfigForFrame:` 把帧换算成 UIDisplayConfiguration 随 settings
 *   一起经 diff 通道下发 —— App 进程才会真的把「自己的屏幕」当成小窗尺寸重排。
 * 本函数把三路杠杆一次配齐、逐路独立记位，哪一路生效真机日志一眼可见：
 *   ① settings.frame（V55 已证写入成功）
 *   ② displayConfiguration.size / sizeInPoints（KVC，@try 探测）
 *   ③ setResidesHostedContext:（Stheno 同款选择子，托管上下文可 resize）
 * ═══════════════════════════════════════════════════════════════════ */

static id AevonSceneDisplayConfiguration(id settings) {
    if (settings == nil) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(@"displayConfiguration");
        if (![settings respondsToSelector:sel]) { return nil; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return fn(settings, sel);
    } @catch (NSException *exception) {
        return nil;
    }
}

/* ── V0.0.60（AevonReflowGateV60）：displayConfiguration 写入重构 ──
 *
 * V0.0.59 真机日志（Aevon(53)）教训：位掩码只有 0x1|0x2|0x40|0x80 ——
 *   size / sizeInPoints 写入（0x4/0x8）、setDisplayConfiguration:（0x10）全失败。
 * 根因：旧代码只找 UIDisplayConfiguration 类做拷贝构造，而 settings.displayConfiguration
 *   里的真实对象很可能是 FBSDisplayConfiguration（FrontBoard 系）—— 类找错了。
 *   并且探测假阳性（测的是我们自己的承载视图）导致 1:1 分支吃到整屏画面 =
 *   「内容放大 + 显示不全」。
 * V0.0.60 三条硬规矩：
 *   ① 以 oldDC 的真实类为操作对象，多策略写尺寸（拷贝/直写/新建），全记位；
 *   ② 每次把 oldDC 的类名与能力表写进诊断串（AevonDisplayConfigDiag），日志直接看；
 *   ③ displayConfiguration 写不进 → 整单放弃（绝不只推 frame —— 那是 V55 的
 *      裁视口症状），Swift 侧据此自动回退整屏等比缩放（V58 形态）。
 */

static char s_dcDiag[512];

/// 最近一次 displayConfiguration 诊断（类名 + 能力表 + ivar 清单 + 方法清单），供 Swift 日志使用。
const char *AevonDisplayConfigDiag(void) { return s_dcDiag; }

static void AevonDcDiag(id obj) {
    if (obj == nil) {
        snprintf(s_dcDiag, sizeof(s_dcDiag), "class=nil（settings 没带 displayConfiguration）");
        return;
    }
    const char *cls = object_getClassName(obj);
    Class realClass = object_getClass(obj);
    BOOL hasSetSize = [obj respondsToSelector:NSSelectorFromString(@"setSize:")];
    BOOL hasSetPts = [obj respondsToSelector:NSSelectorFromString(@"setSizeInPoints:")];
    BOOL hasCopy = [obj respondsToSelector:NSSelectorFromString(@"mutableCopy")];
    BOOL hasDCInit = [realClass instancesRespondToSelector:NSSelectorFromString(@"initWithDisplayConfiguration:")];

    /* V0.0.61（AevonReflowIvarV61）：V60 真机日志证明 FBSDisplayConfiguration
     * 没有 setSize:/sizeInPoints: 选择子 —— 剩下的唯一写入口是 ivar。
     * 这里把 ivar 名单和 size 相关方法名单全部落日志，写不进也能一眼看清
     * 真实布局，下一版不用再猜。 */
    char ivars[512] = "";
    unsigned int ivarCount = 0;
    Ivar *ivarList = class_copyIvarList(realClass, &ivarCount);
    size_t used = 0;
    for (unsigned int i = 0; i < ivarCount && ivarList != NULL; i++) {
        const char *name = ivar_getName(ivarList[i]);
        const char *enc = ivar_getTypeEncoding(ivarList[i]);
        if (name == NULL) { continue; }
        int n = snprintf(ivars + used, sizeof(ivars) - used, "%s%s(%s)",
                         used == 0 ? "" : " ", name, enc ? enc : "?");
        if (n < 0 || (size_t)n >= sizeof(ivars) - used) { break; }
        used += (size_t)n;
    }
    free(ivarList);

    char methods[128] = "";
    unsigned int methodCount = 0;
    Method *methodList = class_copyMethodList(realClass, &methodCount);
    used = 0;
    for (unsigned int i = 0; i < methodCount && methodList != NULL; i++) {
        SEL sel = method_getName(methodList[i]);
        const char *name = sel_getName(sel);
        if (name == NULL) { continue; }
        /* 只收名字里带 size / point 的方法（全部 dump 会爆缓冲） */
        size_t len = strlen(name);
        BOOL hit = NO;
        for (size_t j = 0; j + 4 <= len; j++) {
            if (strncasecmp(name + j, "size", 4) == 0) { hit = YES; break; }
        }
        for (size_t j = 0; !hit && j + 5 <= len; j++) {
            if (strncasecmp(name + j, "point", 5) == 0) { hit = YES; }
        }
        if (!hit) { continue; }
        int n = snprintf(methods + used, sizeof(methods) - used, "%s%s",
                         used == 0 ? "" : " ", name);
        if (n < 0 || (size_t)n >= sizeof(methods) - used) { break; }
        used += (size_t)n;
    }
    free(methodList);

    snprintf(s_dcDiag, sizeof(s_dcDiag),
             "class=%s setSize:%s sizeInPoints:%s mutableCopy:%s initWithDC:%s"
             " 方法[%s] ivar[%s]",
             cls, hasSetSize ? "Y" : "N", hasSetPts ? "Y" : "N",
             hasCopy ? "Y" : "N", hasDCInit ? "Y" : "N",
             methods[0] ? methods : "无", ivars[0] ? ivars : "无");
}

/* ── V0.0.64（AevonReflowAppGateV64）：scene 方法表诊断 ──
 * V63 真机实锤：dc 尺寸用 ivar 直写写进了 settings 且随 diff 下发（回读一致），
 * 但 App 进程没有重排（画面放大）——远程场景事后改 dc 只影响 SB 侧布局。
 * Stheno.dylib 里 `setResizesHostedContext:` 实锤存在（我们调用的是 FBScene，
 * 它不响应该选择子）→ 调用对象一定不是 FBScene 本身。
 * 这里 dump scene 类（含父类）方法表中 host/Context/resize 相关选择子 +
 * scene 上 context 类键的取值类名，下一版照单精准打。 */
static char s_sceneDiag[512];

const char *AevonSceneMethodDiag(void) { return s_sceneDiag; }

static void AevonSceneMethodDiagDump(id scene) {
    if (scene == nil || s_sceneDiag[0] != '\0') { return; }   /* 只 dump 一次 */
    @try {
        char sels[384] = "";
        size_t used = 0;
        Class cls = object_getClass(scene);
        for (int depth = 0; depth < 3 && cls != Nil; depth++) {
            unsigned int count = 0;
            Method *list = class_copyMethodList(cls, &count);
            for (unsigned int i = 0; i < count && list != NULL; i++) {
                const char *name = sel_getName(method_getName(list[i]));
                if (name == NULL) { continue; }
                size_t len = strlen(name);
                BOOL hit = NO;
                for (size_t j = 0; j + 4 <= len && !hit; j++) {
                    if (strncasecmp(name + j, "host", 4) == 0) { hit = YES; }
                    if (strncasecmp(name + j, "cont", 4) == 0 &&
                        strncasecmp(name + j, "constraint", 10) != 0) { hit = YES; }
                }
                for (size_t j = 0; j + 5 <= len && !hit; j++) {
                    if (strncasecmp(name + j, "resiz", 5) == 0) { hit = YES; }
                }
                if (!hit) { continue; }
                int n = snprintf(sels + used, sizeof(sels) - used, "%s%s",
                                 used == 0 ? "" : " ", name);
                if (n < 0 || (size_t)n >= sizeof(sels) - used) { break; }
                used += (size_t)n;
            }
            free(list);
            cls = class_getSuperclass(cls);
        }
        /* context 类键取值（KVC，拿不到就空） */
        const char *ctxCls = "?";
        char ctxBuf[64] = "";
        @try {
            id ctx = [scene valueForKey:@"context"];
            if (ctx != nil) { ctxCls = object_getClassName(ctx); }
        } @catch (NSException *unused) {}
        @try {
            id ctx = [scene valueForKey:@"hostedContext"];
            if (ctx != nil) {
                snprintf(ctxBuf, sizeof(ctxBuf), " hosted=%s", object_getClassName(ctx));
            }
        } @catch (NSException *unused) {}
        snprintf(s_sceneDiag, sizeof(s_sceneDiag),
                 "scene=%s 方法[%s] context=%s%s",
                 object_getClassName(scene), sels[0] ? sels : "无命中", ctxCls, ctxBuf);
    } @catch (NSException *unused) {
        snprintf(s_sceneDiag, sizeof(s_sceneDiag), "scene 诊断异常");
    }
}

/* ── V0.0.61（AevonReflowIvarV61）：ivar 内存直写 ──
 * V60 真机日志（Aevon(54)）：class=FBSDisplayConfiguration，setSize:N sizeInPoints:N
 * mutableCopy:Y —— 选择子/KVC 层面没有任何写入口。剩下唯一没试过的写入口是 ivar：
 * class_copyIvarList 找出名字带 size 的 CGSize 型 ivar（_size / _sizeInPoints 这类），
 * 用 ivar_getOffset 拿偏移、对象内存基址 + 偏移直接 memcpy 目标尺寸。
 * 写完由硬闸门统一裁决：写不进 → 整单放弃回退（与 V60 相同）。 */
static BOOL AevonIvarNameContainsSize(const char *name) {
    if (name == NULL) { return NO; }
    size_t len = strlen(name);
    for (size_t j = 0; j + 4 <= len; j++) {
        if (strncasecmp(name + j, "size", 4) == 0) { return YES; }
    }
    return NO;
}

static BOOL AevonWriteDcIvar(id obj, CGSize target, int *outBits) {
    if (obj == nil) { return NO; }
    @try {
        Class cls = object_getClass(obj);
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (ivars == NULL) { return NO; }
        char *base = (char *)(__bridge void *)obj;
        BOOL wrote = NO;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            if (name == NULL || enc == NULL) { continue; }
            /* 只动「名字带 size」的 CGSize ivar（_size / _sizeInPoints / size...），
             * 绝不盲写其它 CGSize 字段（比如 minimum/native 之类会破坏现场）。 */
            if (!AevonIvarNameContainsSize(name)) { continue; }
            if (strncmp(enc, "{CGSize", 7) != 0) { continue; }
            ptrdiff_t off = ivar_getOffset(ivars[i]);
            memcpy(base + off, &target, sizeof(CGSize));
            wrote = YES;
            *outBits |= (strstr(name, "oint") != NULL) ? 0x8 : 0x4;
        }
        free(ivars);
        return wrote;
    } @catch (NSException *exception) {
        return NO;
    }
}

/// 尽力把 candidate 的逻辑尺寸改成 target。
/// bit4 = size 写入 / bit8 = sizeInPoints 写入。全部失败返回 NO。
static BOOL AevonWriteDcSize(id candidate, CGSize target, int *outBits) {
    if (candidate == nil) { return NO; }
    @try {
        SEL setSel = NSSelectorFromString(@"setSize:");
        if ([candidate respondsToSelector:setSel]) {
            void (*fn)(id, SEL, CGSize) = (void (*)(id, SEL, CGSize))objc_msgSend;
            fn(candidate, setSel, target);
            *outBits |= 0x4;
            return YES;
        }
        NSValue *boxed = [NSValue valueWithCGSize:target];
        @try {
            [candidate setValue:boxed forKey:@"size"];
            *outBits |= 0x4;
            return YES;
        } @catch (NSException *unused) {}
        @try {
            [candidate setValue:boxed forKey:@"_size"];
            *outBits |= 0x4;
            return YES;
        } @catch (NSException *unused) {}
        SEL setPointsSel = NSSelectorFromString(@"setSizeInPoints:");
        if ([candidate respondsToSelector:setPointsSel]) {
            void (*fn)(id, SEL, CGSize) = (void (*)(id, SEL, CGSize))objc_msgSend;
            fn(candidate, setPointsSel, target);
            *outBits |= 0x8;
            return YES;
        }
        @try {
            [candidate setValue:boxed forKey:@"sizeInPoints"];
            *outBits |= 0x8;
            return YES;
        } @catch (NSException *unused) {}
        @try {
            [candidate setValue:boxed forKey:@"_sizeInPoints"];
            *outBits |= 0x8;
            return YES;
        } @catch (NSException *unused) {}
        /* V0.0.61：最后一层 —— ivar 内存直写（AevonReflowIvarV61） */
        if (AevonWriteDcIvar(candidate, target, outBits)) {
            *outBits |= 0x800;
            return YES;
        }
        return NO;
    } @catch (NSException *exception) {
        return NO;
    }
}

static id AevonAllocInit(Class cls) {
    if (cls == Nil) { return nil; }
    id (*allocFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id raw = allocFn((id)cls, NSSelectorFromString(@"alloc"));
    if (raw == nil) { return nil; }
    id (*initFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return initFn(raw, NSSelectorFromString(@"init"));
}

/// 尽力把一个 displayConfiguration 的逻辑尺寸改成 target。
/// 成功返回（可能就地改写的）配置对象，失败返回 nil。
/// 策略位：0x100 = 旧配置拷贝 / 0x200 = 原对象直写 / 0x400 = 新建配置。
/// V0.0.62（AevonReflowIvarV61 AevonPolicyTryV62）重大修复：**每个策略独立 @try**。
/// V61 真机日志（Aevon(55)）暴露：策略 A 的 mutableCopy 运行时抛异常
/// （respondsToSelector:YES 不代表调用成功），被本函数外层 @catch 一刀切
/// return nil —— 策略 B（原对象 ivar 直写）从未执行，这就是「策略位全无」的真相。
static id AevonResizeDisplayConfiguration(id oldDC, CGSize target, int *outBits) {
    if (oldDC == nil) { return nil; }
    AevonDcDiag(oldDC);

    /* 策略 A：旧配置 mutableCopy（保留 displayID / mode 现场）再写尺寸 —— 独立 try */
    @try {
        SEL copySel = NSSelectorFromString(@"mutableCopy");
        if ([oldDC respondsToSelector:copySel]) {
            id (*doCopy)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id copied = doCopy(oldDC, copySel);
            if (copied != nil && AevonWriteDcSize(copied, target, outBits)) {
                *outBits |= 0x100;
                return copied;
            }
        }
    } @catch (NSException *unused) {}

    /* 策略 B：原对象直写（oldDC 来自我们刚 mutableCopy 的 settings，就地改无副作用）。
     * FBSDisplayConfiguration 无任何 setter —— 到这里就是 ivar 内存直写（_pixelSize）。 */
    @try {
        if (AevonWriteDcSize(oldDC, target, outBits)) {
            *outBits |= 0x200;
            return oldDC;
        }
    } @catch (NSException *unused) {}

    /* 策略 C：以真实类拷贝构造 / 新建（保留旧 UIDisplayConfiguration 兜底）—— 独立 try */
    @try {
        Class realClass = object_getClass(oldDC);
        SEL dcCopy = NSSelectorFromString(@"initWithDisplayConfiguration:");
        id candidate = nil;
        if ([realClass instancesRespondToSelector:dcCopy]) {
            id (*allocFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id raw = allocFn((id)realClass, NSSelectorFromString(@"alloc"));
            id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            candidate = initFn(raw, dcCopy, oldDC);
        }
        if (candidate == nil) {
            candidate = AevonAllocInit(realClass);
        }
        if (candidate != nil && AevonWriteDcSize(candidate, target, outBits)) {
            *outBits |= 0x400;
            return candidate;
        }
    } @catch (NSException *unused) {}

    @try {
        Class ui = NSClassFromString(@"UIDisplayConfiguration");
        Class realClass2 = object_getClass(oldDC);
        if (ui != Nil && ui != realClass2) {
            SEL dcCopy = NSSelectorFromString(@"initWithDisplayConfiguration:");
            id candidate = nil;
            if ([ui instancesRespondToSelector:dcCopy]) {
                id (*allocFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id raw = allocFn((id)ui, NSSelectorFromString(@"alloc"));
                id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                candidate = initFn(raw, dcCopy, oldDC);
            }
            if (candidate == nil) {
                candidate = AevonAllocInit(ui);
            }
            if (candidate != nil && AevonWriteDcSize(candidate, target, outBits)) {
                *outBits |= 0x400;
                return candidate;
            }
        }
    } @catch (NSException *unused) {}
    return nil;
}

CGSize AevonSceneDisplaySize(id scene) {
    @try {
        SEL settingsSel = NSSelectorFromString(@"settings");
        if (scene == nil || ![scene respondsToSelector:settingsSel]) { return CGSizeZero; }
        id (*getSettings)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id settings = getSettings(scene, settingsSel);
        id dc = AevonSceneDisplayConfiguration(settings);
        if (dc == nil) { return CGSizeZero; }
        SEL sizeSel = NSSelectorFromString(@"size");
        if ([dc respondsToSelector:sizeSel]) {
            CGSize (*fn)(id, SEL) = (CGSize (*)(id, SEL))objc_msgSend;
            return fn(dc, sizeSel);
        }
        SEL pointsSel = NSSelectorFromString(@"sizeInPoints");
        if ([dc respondsToSelector:pointsSel]) {
            CGSize (*fn)(id, SEL) = (CGSize (*)(id, SEL))objc_msgSend;
            return fn(dc, pointsSel);
        }
        return CGSizeZero;
    } @catch (NSException *exception) {
        return CGSizeZero;
    }
}

int AevonSceneApplyDisplaySize(id scene, CGSize size, BOOL floatMode) {
    int bits = 0;
    AevonSceneMethodDiagDump(scene);
    if (scene == nil || size.width < 1.0 || size.height < 1.0) { return bits; }
    @try {
        SEL settingsSel = NSSelectorFromString(@"settings");
        if (![scene respondsToSelector:settingsSel]) { return bits; }
        id (*getSettings)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id settings = getSettings(scene, settingsSel);
        if (settings == nil) { return bits; }

        SEL copySel = NSSelectorFromString(@"mutableCopy");
        if (![settings respondsToSelector:copySel]) { return bits; }
        id (*doCopy)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id mutable = doCopy(settings, copySel);
        if (mutable == nil) { return bits; }

        /* V0.0.60（AevonReflowGateV60）：先攻 displayConfiguration ——
         * 写不进就整单放弃。绝不只推 frame：V55 已证只改 frame = 只裁渲染视口
         * （App 照旧按整屏渲染，塞进小视口 = 内容放大 + 显示不全），
         * V0.0.59 的「放大 + 显示不全」正是探测假阳性 + 只推 frame 的组合。 */
        id oldDC = AevonSceneDisplayConfiguration(mutable);
        if (oldDC != nil) { bits |= 0x2; }
        id newDC = AevonResizeDisplayConfiguration(oldDC, size, &bits);
        if (newDC == nil) {
            /* 不写 frame、不推 diff、不记 adaptiveFrames —— 场景保持整屏，
             * Swift 侧自动回退 V58 整屏等比缩放（干净回退，最坏=上一版形态）。 */
            return bits;
        }

        /* 杠杆 ①：frame（displayConfiguration 成立后才一起写） */
        if (AevonSettingsSetFrame(mutable, CGRectMake(0, 0, size.width, size.height))) {
            bits |= 0x1;
        }

        /* 杠杆 ②：displayConfiguration 随帧一起下发（Mango 实证的关键差异） */
        SEL setDCSel = NSSelectorFromString(@"setDisplayConfiguration:");
        if (![mutable respondsToSelector:setDCSel]) { return bits; }
        void (*setFn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        setFn(mutable, setDCSel, newDC);
        bits |= 0x10;

        /* 杠杆 ③：托管上下文可 resize（Stheno 同款选择子，存在才调） */
        if (floatMode) {
            SEL resizeSel = NSSelectorFromString(@"setResizesHostedContext:");
            if ([scene respondsToSelector:resizeSel]) {
                void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
                fn(scene, resizeSel, YES);
                bits |= 0x20;
            }
        }

        /* 下发：官方 diff 通道（与 Stheno / Mango 同一收口） */
        SEL updateSel = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        SEL updateShortSel = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        BOOL pushed = NO;
        if ([scene respondsToSelector:updateSel]) {
            void (*fn)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))objc_msgSend;
            fn(scene, updateSel, mutable, nil, nil);
            pushed = YES;
        } else if ([scene respondsToSelector:updateShortSel]) {
            void (*fn)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
            fn(scene, updateShortSel, mutable, nil);
            pushed = YES;
        }
        if (pushed) { bits |= 0x40; }

        /* 回读校验（±1pt） */
        CGSize now = AevonSceneFrameSize(scene);
        if (fabs(now.width - size.width) <= 1.0 && fabs(now.height - size.height) <= 1.0) {
            bits |= 0x80;
        }
        return bits;
    } @catch (NSException *exception) {
        return bits;
    }
}

/* V0.0.59：在一份（可变）settings 对象上把 displayConfiguration 尺寸改到 target。
 * 供 FBScene updateSettings 钩子使用 —— 系统每次推新 settings 都可能把
 * displayConfiguration 带回整屏，钩子在透传前盖回去（与 frame 顶回同一时机）。 */
BOOL AevonSettingsApplyDisplaySize(id settings, CGSize size) {
    if (settings == nil || size.width < 1.0 || size.height < 1.0) { return NO; }
    @try {
        id oldDC = AevonSceneDisplayConfiguration(settings);
        int bits = 0;
        id newDC = AevonResizeDisplayConfiguration(oldDC, size, &bits);
        if (newDC == nil) { return NO; }
        SEL setDCSel = NSSelectorFromString(@"setDisplayConfiguration:");
        if (![settings respondsToSelector:setDCSel]) { return NO; }
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        fn(settings, setDCSel, newDC);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

#pragma mark - V0.0.75（AevonCrashFuseV75）：P1 崩溃防护三件套

NSString *AevonSafeClassName(id obj) {
    if (obj == nil) { return @"nil"; }
    /* 只用 runtime 读类指针：object_getClass 对合法对象永远安全，
     * 而 Swift 的 type(of:) 会走 swift_getObjectType —— 对象指针是 0x1（BOOL）
     * 这类非法值时直接读野 isa 崩溃（Aevon(67) 自动注销的根因）。 */
    Class c = object_getClass(obj);
    if (c == Nil) { return @"?"; }
    const char *n = class_getName(c);
    if (n == NULL) { return @"?"; }
    return [NSString stringWithUTF8String:n] ?: @"?";
}

BOOL AevonSafeBoolCall(id obj, NSString *selectorName, BOOL *ok) {
    if (ok) { *ok = NO; }
    if (obj == nil || selectorName.length == 0) { return NO; }
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        if (sel == NULL || ![obj respondsToSelector:sel]) { return NO; }
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (m == NULL) { return NO; }
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        /* B = C++ bool / c = char / i = int：只有这几种才按 BOOL 调。
         * 返回对象（@）的绝不能走这条路 —— 那才是安全的 perform 途径。 */
        if (ret[0] != 'B' && ret[0] != 'c' && ret[0] != 'i') { return NO; }
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(m);
        BOOL v = fn(obj, sel);
        if (ok) { *ok = YES; }
        return v;
    } @catch (NSException *e) {
        if (ok) { *ok = NO; }
        return NO;
    }
}

/* 面包屑文件：与 Aevon.log 同目录（/var/mobile），respring 不会清。
 * 只在 P1 实验期间存在，正常走完立刻删除。 */
static const char *kAevonCrumbPath = "/var/mobile/Aevon.p1crumb";
static char s_crumbBuf[128];

void AevonCrumbWrite(const char *stage) {
    @try {
        if (stage == NULL) { return; }
        NSString *s = [NSString stringWithUTF8String:stage] ?: @"?";
        /* 带时间戳，日志里能看出崩在各轮的第几秒 */
        NSString *line = [NSString stringWithFormat:@"%.0f %@",
                          [[NSDate date] timeIntervalSince1970], s];
        [line writeToFile:[NSString stringWithUTF8String:kAevonCrumbPath]
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:NULL];
    } @catch (NSException *e) { }
}

const char *AevonCrumbRead(void) {
    s_crumbBuf[0] = '\0';
    @try {
        NSString *s = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:kAevonCrumbPath]
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        if (s.length > 0) {
            const char *utf8 = [s UTF8String];
            if (utf8 != NULL) {
                strncpy(s_crumbBuf, utf8, sizeof(s_crumbBuf) - 1);
                s_crumbBuf[sizeof(s_crumbBuf) - 1] = '\0';
            }
        }
    } @catch (NSException *e) { }
    return s_crumbBuf;
}

void AevonCrumbClear(void) {
    @try {
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:kAevonCrumbPath]
                                                   error:NULL];
    } @catch (NSException *e) { }
    s_crumbBuf[0] = '\0';
}

#pragma mark - V0.0.75：返回值类型安全的方法调用

id AevonSafeCallObject(id obj, NSString *selectorName) {
    if (obj == nil || selectorName.length == 0) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        if (sel == NULL || ![obj respondsToSelector:sel]) { return nil; }
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (m == NULL) { return nil; }
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        /* 只认对象返回值；BOOL/整数/浮点/结构体一律拒绝（那些走 AevonSafeBoolCall） */
        if (ret[0] != '@') { return nil; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))method_getImplementation(m);
        return fn(obj, sel);
    } @catch (NSException *e) {
        return nil;
    }
}

id AevonSafeCallObject1(id obj, NSString *selectorName, id arg1) {
    if (obj == nil || selectorName.length == 0) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        if (sel == NULL || ![obj respondsToSelector:sel]) { return nil; }
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (m == NULL) { return nil; }
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        if (ret[0] != '@') { return nil; }
        id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))method_getImplementation(m);
        return fn(obj, sel, arg1);
    } @catch (NSException *e) {
        return nil;
    }
}

id AevonSafeCallObject2(id obj, NSString *selectorName, id arg1, id arg2) {
    if (obj == nil || selectorName.length == 0) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        if (sel == NULL || ![obj respondsToSelector:sel]) { return nil; }
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (m == NULL) { return nil; }
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        if (ret[0] != '@') { return nil; }
        id (*fn)(id, SEL, id, id) = (id (*)(id, SEL, id, id))method_getImplementation(m);
        return fn(obj, sel, arg1, arg2);
    } @catch (NSException *e) {
        return nil;
    }
}

id AevonSafeReadObjectIvar(id obj, const char *ivarName) {
    if (obj == nil || ivarName == NULL) { return nil; }
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(obj), ivarName);
        if (iv == NULL) { return nil; }
        const char *enc = ivar_getTypeEncoding(iv);
        if (enc == NULL || enc[0] != '@') { return nil; }
        return object_getIvar(obj, iv);
    } @catch (NSException *e) {
        return nil;
    }
}

id AevonSafeCallObjectSel(id obj, SEL sel) {
    if (obj == nil || sel == NULL) { return nil; }
    @try {
        if (![obj respondsToSelector:sel]) { return nil; }
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (m == NULL) { return nil; }
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        if (ret[0] != '@') { return nil; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))method_getImplementation(m);
        return fn(obj, sel);
    } @catch (NSException *e) {
        return nil;
    }
}

#pragma mark - V0.0.76（AevonSceneSafeObjV76）：静态类型化的安全调用

/* CI 标记（V0.0.76）：本段必须编进主 dylib —— Aevon(68) 自动注销的根治点。 */
__attribute__((used)) static const char AevonSceneSafeObjV76Marker[] = "AevonSceneSafeObjV76";
__attribute__((used)) static const char AevonSceneProxyObjCV76Marker[] = "AevonP1ProxyObjCV76";

/* 指针体检：不是干净对象就返回 nil，绝不把脏指针带进 Swift。
 * 历史两次自动注销的元凶：BOOL 返回值 1（奇地址）被当成对象指针、
 * 结构体返回值被当成对象指针。 */
static id AevonVerifiedObject(id p) {
    if (p == nil) { return nil; }
    uintptr_t v = (uintptr_t)p;
    if ((v & 1ULL) != 0) { return nil; }          /* tagged / BOOL 1 / 小整数 */
    if (v < 0x100000000ULL) { return nil; }        /* arm64 上不可能是合法对象 */
    if ((v & 7ULL) != 0) { return nil; }           /* 对象至少 8 字节对齐 */
    @try {
        Class c = object_getClass(p);
        if (c == Nil) { return nil; }
        if (class_isMetaClass(c)) { return nil; }
        if (class_getName(c) == NULL) { return nil; }
    } @catch (NSException *e) {
        return nil;
    }
    return p;
}

/// 统一取实现 + 校验返回值编码是 '@'（只认对象）
static IMP AevonObjectIMP(id obj, SEL sel) {
    if (obj == nil || sel == NULL) { return NULL; }
    if (![obj respondsToSelector:sel]) { return NULL; }
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (m == NULL) { return NULL; }
    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != '@') { return NULL; }
    return method_getImplementation(m);
}

NSObject *AevonSafeObjCallSel(id obj, SEL sel) {
    @try {
        IMP imp = AevonObjectIMP(obj, sel);
        if (imp == NULL) { return nil; }
        return AevonVerifiedObject(((id (*)(id, SEL))imp)(obj, sel));
    } @catch (NSException *e) { return nil; }
}

NSObject *AevonSafeObjCall(id obj, NSString *selectorName) {
    if (selectorName.length == 0) { return nil; }
    return AevonSafeObjCallSel(obj, NSSelectorFromString(selectorName));
}

NSObject *AevonSafeObjCall1(id obj, NSString *selectorName, id arg1) {
    if (selectorName.length == 0) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        IMP imp = AevonObjectIMP(obj, sel);
        if (imp == NULL) { return nil; }
        return AevonVerifiedObject(((id (*)(id, SEL, id))imp)(obj, sel, arg1));
    } @catch (NSException *e) { return nil; }
}

NSObject *AevonSafeObjCall2(id obj, NSString *selectorName, id arg1, id arg2) {
    if (selectorName.length == 0) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        IMP imp = AevonObjectIMP(obj, sel);
        if (imp == NULL) { return nil; }
        return AevonVerifiedObject(((id (*)(id, SEL, id, id))imp)(obj, sel, arg1, arg2));
    } @catch (NSException *e) { return nil; }
}

NSObject *AevonSafeObjIvar(id obj, const char *ivarName) {
    if (obj == nil || ivarName == NULL) { return nil; }
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(obj), ivarName);
        if (iv == NULL) { return nil; }
        const char *enc = ivar_getTypeEncoding(iv);
        if (enc == NULL || enc[0] != '@') { return nil; }
        return AevonVerifiedObject(object_getIvar(obj, iv));
    } @catch (NSException *e) { return nil; }
}

NSObject *AevonAllocInstance(Class cls) {
    if (cls == Nil || class_isMetaClass((Class)cls) == NO) { return nil; }
    @try {
        return AevonVerifiedObject(((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc)));
    } @catch (NSException *e) { return nil; }
}

Class AevonClassOfObject(id obj) {
    if (obj == nil) { return Nil; }
    @try { return object_getClass(obj); } @catch (NSException *e) { return Nil; }
}

Class AevonClassNamed(NSString *name) {
    if (name.length == 0) { return Nil; }
    return NSClassFromString(name);
}

BOOL AevonClassRespondsTo(Class cls, NSString *selectorName) {
    if (cls == Nil || selectorName.length == 0) { return NO; }
    @try { return [(id)cls respondsToSelector:NSSelectorFromString(selectorName)]; }
    @catch (NSException *e) { return NO; }
}

BOOL AevonClassHasInstanceMethod(Class cls, NSString *selectorName) {
    if (cls == Nil || selectorName.length == 0) { return NO; }
    return class_getInstanceMethod((Class)cls, NSSelectorFromString(selectorName)) != NULL;
}

BOOL AevonObjRespondsTo(id obj, NSString *selectorName) {
    if (obj == nil || selectorName.length == 0) { return NO; }
    @try { return [obj respondsToSelector:NSSelectorFromString(selectorName)]; }
    @catch (NSException *e) { return NO; }
}

#pragma mark - provider 代理（纯 ObjC）

static int s_aevonProxyHits = 0;

@interface AevonSceneHandleProviderProxy : NSObject
@property (nonatomic, strong) id target;
@end

@implementation AevonSceneHandleProviderProxy

/* 四段 init 内部会向 provider 要「这个 App 的主场景身份」。
 * iOS 17.3.1 的 SBMainWorkspace 没实现这个协议方法，只实现了下划线变体，
 * 所以这里原样转调；两套命名都试，全失败返回 nil（系统会自己报错，不崩进程）。 */
- (id)sceneIdentityForApplication:(id)app
          createPrimaryIfRequired:(BOOL)createPrimary
                 sceneSessionRole:(id)role {
    s_aevonProxyHits++;
    id target = self.target;
    if (target == nil) { return nil; }
    NSArray<NSString *> *names = @[
        @"_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:",
        @"_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:error:",
        @"sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:error:"
    ];
    for (NSString *n in names) {
        SEL alt = NSSelectorFromString(n);
        if (alt == NULL || ![target respondsToSelector:alt]) { continue; }
        Method m = class_getInstanceMethod(object_getClass(target), alt);
        if (m == NULL) { continue; }
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        if (ret[0] != '@') { continue; }
        IMP imp = method_getImplementation(m);
        @try {
            if ([n hasSuffix:@"error:"]) {
                id out = nil;
                id r = ((id (*)(id, SEL, id, BOOL, id, id *))imp)(target, alt, app, createPrimary, role, &out);
                if (r != nil) { return r; }
            } else {
                id r = ((id (*)(id, SEL, id, BOOL, id))imp)(target, alt, app, createPrimary, role);
                if (r != nil) { return r; }
            }
        } @catch (NSException *e) { }
    }
    /* 最后一招：只要实参是 SBApplication，直接问它自己的主场景身份（等价语义）。 */
    @try {
        for (NSString *n in @[@"_mainSceneIdentity", @"mainSceneIdentity", @"primarySceneIdentity"]) {
            SEL s = NSSelectorFromString(n);
            if ([target respondsToSelector:s]) {
                id r = ((id (*)(id, SEL))method_getImplementation(class_getInstanceMethod(object_getClass(target), s)))(target, s);
                if (r != nil) { return r; }
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

@end

NSObject *AevonProviderProxyCreate(id target) {
    @try {
        AevonSceneHandleProviderProxy *p = [[AevonSceneHandleProviderProxy alloc] init];
        p.target = target;
        return p;
    } @catch (NSException *e) { return nil; }
}

int AevonProviderProxyHitCount(void) { return s_aevonProxyHits; }

#pragma mark - P1 崩溃计数

static const char *kAevonP1FusePath = "/var/mobile/Aevon.p1fuse";

int AevonP1FuseCount(void) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:kAevonP1FusePath]
                                                encoding:NSUTF8StringEncoding error:NULL];
        return s.length ? s.intValue : 0;
    } @catch (NSException *e) { return 0; }
}

void AevonP1FuseBump(void) {
    @try {
        int n = AevonP1FuseCount() + 1;
        NSString *s = [NSString stringWithFormat:@"%d", n];
        [s writeToFile:[NSString stringWithUTF8String:kAevonP1FusePath]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) { }
}

void AevonP1FuseReset(void) {
    @try {
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:kAevonP1FusePath]
                                                   error:NULL];
    } @catch (NSException *e) { }
}

#pragma mark - KVC 安全版（Swift 无法捕获 ObjC 异常）

BOOL AevonSafeSetValueForKey(id obj, id value, NSString *key) {
    if (obj == nil || key.length == 0) { return NO; }
    @try { [obj setValue:value forKey:key]; return YES; }
    @catch (NSException *e) { return NO; }
}

BOOL AevonSafeSetValueForKeyPath(id obj, id value, NSString *keyPath) {
    if (obj == nil || keyPath.length == 0) { return NO; }
    @try { [obj setValue:value forKeyPath:keyPath]; return YES; }
    @catch (NSException *e) { return NO; }
}

NSObject *AevonSafeValueForKey(id obj, NSString *key) {
    if (obj == nil || key.length == 0) { return nil; }
    @try { return AevonVerifiedObject([obj valueForKey:key]); }
    @catch (NSException *e) { return nil; }
}

NSObject *AevonSafeValueForKeyPath(id obj, NSString *keyPath) {
    if (obj == nil || keyPath.length == 0) { return nil; }
    @try { return AevonVerifiedObject([obj valueForKeyPath:keyPath]); }
    @catch (NSException *e) { return nil; }
}

Class AevonMetaClassNamed(NSString *name) {
    if (name.length == 0) { return Nil; }
    return objc_getMetaClass(name.UTF8String);
}

#pragma mark - V0.0.77（AevonSceneScanObjCV77）：类扫描 + Guard 存活登记

/* CI 标记（V0.0.77）：本段必须编进主 dylib —— Aevon(69) 第二次自动注销的根治点。 */
__attribute__((used)) static const char AevonSceneScanObjCV77Marker[] = "AevonSceneScanObjCV77";
__attribute__((used)) static const char AevonGuardAliveV77Marker[] = "AevonGuardAliveV77";

NSString *AevonClassScanForSelector(NSString *selName, int limit) {
    if (selName.length == 0 || limit <= 0) { return @""; }
    @try {
        SEL sel = NSSelectorFromString(selName);
        if (sel == NULL) { return @""; }
        unsigned int count = 0;
        Class *list = objc_copyClassList(&count);
        if (list == NULL) { return @""; }
        NSMutableArray<NSString *> *out = [NSMutableArray array];
        for (unsigned int i = 0; i < count && (int)out.count < limit; i++) {
            Class c = list[i];
            if (c == Nil) { continue; }
            /* 纯 ObjC：只看方法表，不碰对象、不做任何转换 */
            if (class_getInstanceMethod(c, sel) != NULL) {
                const char *n = class_getName(c);
                if (n != NULL) {
                    [out addObject:[NSString stringWithUTF8String:n]];
                }
            }
        }
        free(list);
        return out.count ? [out componentsJoinedByString:@","] : @"";
    } @catch (NSException *e) {
        return @"";
    }
}

NSString *AevonClassNameOfClass(Class cls) {
    if (cls == Nil) { return @"nil"; }
    @try {
        const char *n = class_getName(cls);
        if (n == NULL) { return @"nil"; }
        if (class_isMetaClass(cls)) {
            return [NSString stringWithFormat:@"%s(元类)", n];
        }
        return [NSString stringWithUTF8String:n];
    } @catch (NSException *e) {
        return @"nil";
    }
}

int AevonGuardAliveState(NSString *bundleID) {
    if (bundleID.length == 0) { return 0; }
    /* V0.0.78（AevonAliveFileV78）：**文件优先**。
     * Aevon(70) 实测：Guard 明明在 6 个 App 进程里都在打日志（吞摸取证带着对应 bundle），
     * notify state 读回来全是 0 —— 6 个浮窗全被误判成「无 Guard」而关掉了内容触摸。
     * 文件 + kill(pid,0) 这条路 Aevon.log 已经证明可用（App 进程能写 /var/mobile），
     * 读到就直接返回；读不到再退回 notify state。 */
    int filePid = AevonGuardAliveFileState(bundleID);
    if (filePid > 0) { return filePid; }
    @try {
        NSString *name = [@"com.aevon.alive." stringByAppendingString:bundleID];
        int token = -1;
        if (notify_register_check(name.UTF8String, &token) != 0 || token < 0) {
            return 0;
        }
        uint64_t st = 0;
        if (notify_get_state(token, &st) != 0) {
            notify_cancel(token);
            return 0;
        }
        notify_cancel(token);
        return (int)(st & 0x7FFFFFFF);
    } @catch (NSException *e) {
        return 0;
    }
}

#pragma mark - V0.0.78（AevonProviderGraphV78）：对象图 BFS + 文件式存活

/* CI 标记（V0.0.78）：本段必须编进主 dylib —— P1 第 4 步 provider 真身。 */
__attribute__((used)) static const char AevonProviderGraphV78Marker[] = "AevonProviderGraphV78";
__attribute__((used)) static const char AevonAliveFileV78Marker[] = "AevonAliveFileV78";

/// 这些类只是容器 / 值对象，继续往下钻既没意义又会爆炸
static BOOL AevonGraphSkipClass(Class c) {
    if (c == Nil) { return YES; }
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"NSString", @"NSArray", @"NSDictionary", @"NSSet", @"NSNumber", @"NSValue",
                     @"NSData", @"NSDate", @"NSURL", @"NSError", @"NSIndexSet", @"NSOrderedSet",
                     @"NSAttributedString", @"FBSSceneSettings", @"FBSDisplayConfiguration",
                     @"CALayer", @"NSMutable", @"__NS"];
    });
    const char *n = class_getName(c);
    if (n == NULL) { return YES; }
    NSString *name = [NSString stringWithUTF8String:n];
    if (name.length == 0) { return YES; }
    if ([name hasPrefix:@"Swift."] || [name hasPrefix:@"_NS"]) { return YES; }
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) { return YES; }
    }
    return NO;
}

/// 收集对象自身的对象型 ivar（只认 '@' 编码 —— V62 崩溃教训）
static NSArray *AevonGraphObjectIvars(id obj) {
    if (obj == nil) { return @[]; }
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class c = object_getClass(obj);
        if (c == Nil || class_isMetaClass(c)) { return @[]; }
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        if (ivars == NULL) { return @[]; }
        for (unsigned int i = 0; i < count; i++) {
            Ivar iv = ivars[i];
            const char *enc = ivar_getTypeEncoding(iv);
            if (enc == NULL || enc[0] != '@') { continue; }   /* 非对象，直接跳过 */
            id v = object_getIvar(obj, iv);
            if (v == nil) { continue; }
            if (AevonGraphSkipClass(object_getClass(v))) { continue; }
            [out addObject:v];
        }
        free(ivars);
    } @catch (NSException *e) { }
    return out;
}

NSObject *AevonFindResponderInGraph(id root, NSString *selName, NSString *preferToken, int depth) {
    if (root == nil || selName.length == 0) { return nil; }
    SEL sel = NSSelectorFromString(selName);
    if (sel == NULL) { return nil; }
    NSMutableArray *level = [NSMutableArray arrayWithObject:root];
    NSMutableArray *seen = [NSMutableArray array];
    NSObject *firstHit = nil;
    int nodes = 0;
    for (int d = 0; d <= MAX(depth, 0) && level.count > 0 && nodes < 600; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (id node in level) {
            if (node == nil || nodes >= 600) { continue; }
            nodes += 1;
            @try {
                /* 用 respondsToSelector（真实判定），命中就按 preferToken 择优返回 */
                if ([node respondsToSelector:sel]) {
                    const char *cn = class_getName(object_getClass(node));
                    NSString *cname = cn ? [NSString stringWithUTF8String:cn] : @"";
                    if (preferToken.length > 0 && [cname containsString:preferToken]) {
                        return node;
                    }
                    if (firstHit == nil) { firstHit = node; }
                }
                /* 防止环 / 重复 */
                NSString *ptr = [NSString stringWithFormat:@"%p", node];
                if ([seen containsObject:ptr]) { continue; }
                [seen addObject:ptr];
                for (id child in AevonGraphObjectIvars(node)) {
                    [next addObject:child];
                }
            } @catch (NSException *e) { }
        }
        level = next;
    }
    return firstHit;
}

NSString *AevonGraphResponderReport(id root, NSString *selName, int depth, int limit) {
    if (root == nil || selName.length == 0 || limit <= 0) { return @""; }
    SEL sel = NSSelectorFromString(selName);
    if (sel == NULL) { return @""; }
    NSMutableArray *level = [NSMutableArray arrayWithObject:root];
    NSMutableArray *seen = [NSMutableArray array];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    int nodes = 0;
    for (int d = 0; d <= MAX(depth, 0) && level.count > 0 && nodes < 600 && (int)hits.count < limit; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (id node in level) {
            if (node == nil || nodes >= 600 || (int)hits.count >= limit) { continue; }
            nodes += 1;
            @try {
                if ([node respondsToSelector:sel]) {
                    const char *cn = class_getName(object_getClass(node));
                    NSString *cname = cn ? [NSString stringWithUTF8String:cn] : @"?";
                    if (![hits containsObject:cname]) { [hits addObject:cname]; }
                }
                NSString *ptr = [NSString stringWithFormat:@"%p", node];
                if ([seen containsObject:ptr]) { continue; }
                [seen addObject:ptr];
                for (id child in AevonGraphObjectIvars(node)) { [next addObject:child]; }
            } @catch (NSException *e) { }
        }
        level = next;
    }
    return hits.count ? [hits componentsJoinedByString:@","] : @"";
}

#pragma mark - V0.0.79：带容器展开的 ivar 候选（AevonProviderIvarV79）

/* 纯 ObjC、只用公开运行时 API，任何一步都在 @try 里：
 * 这些对象都是系统单例，读 ivar 只读不写，失败最多是少一条线索。 */

static NSString *AevonPtrKey(id obj) {
    return [NSString stringWithFormat:@"%p", obj];
}

static BOOL AevonIsContainerObject(id v) {
    if (v == nil) { return NO; }
    @try {
        if ([v isKindOfClass:[NSArray class]]) { return YES; }
        if ([v isKindOfClass:[NSDictionary class]]) { return YES; }
        if ([v isKindOfClass:[NSSet class]]) { return YES; }
        if ([v isKindOfClass:[NSOrderedSet class]]) { return YES; }
    } @catch (NSException *e) { }
    return NO;
}

/// 容器里前 8 个「像对象的东西」（跳过字符串 / 数字 / 值包装）
static NSArray *AevonContainerPeek(id v) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        NSArray *items = nil;
        if ([v isKindOfClass:[NSDictionary class]]) { items = [(NSDictionary *)v allValues]; }
        if (items == nil && [v isKindOfClass:[NSSet class]]) { items = [(NSSet *)v allObjects]; }
        if (items == nil && [v isKindOfClass:[NSOrderedSet class]]) { items = [(NSOrderedSet *)v array]; }
        if (items == nil && [v isKindOfClass:[NSArray class]]) { items = (NSArray *)v; }
        int n = 0;
        for (id it in items) {
            if (n >= 8) { break; }
            n += 1;
            if (it == nil) { continue; }
            Class c = object_getClass(it);
            if (c == Nil || class_isMetaClass(c)) { continue; }
            const char *cn = class_getName(c);
            if (cn == NULL) { continue; }
            NSString *name = [NSString stringWithUTF8String:cn];
            if (name.length == 0) { continue; }
            if ([name hasPrefix:@"NSString"] || [name hasPrefix:@"NSNumber"]
                || [name hasPrefix:@"NSValue"] || [name hasPrefix:@"NSData"]
                || [name hasPrefix:@"NSDate"] || [name hasPrefix:@"NSURL"]) { continue; }
            [out addObject:it];
        }
    } @catch (NSException *e) { }
    return out;
}

NSArray *AevonIvarCandidates(id root) {
    NSMutableArray *out = [NSMutableArray array];
    if (root == nil) { return out; }
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *layer = [NSMutableArray arrayWithObject:root];
    for (int d = 0; d < 2; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (id node in layer) {
            @try {
                NSString *key = AevonPtrKey(node);
                if ([seen containsObject:key]) { continue; }
                [seen addObject:key];
                Class c = object_getClass(node);
                if (c == Nil || class_isMetaClass(c)) { continue; }
                unsigned int count = 0;
                Ivar *ivars = class_copyIvarList(c, &count);
                if (ivars == NULL) { continue; }
                for (unsigned int i = 0; i < count && out.count < 200; i++) {
                    const char *enc = ivar_getTypeEncoding(ivars[i]);
                    if (enc == NULL || enc[0] != '@') { continue; }
                    /* 系统单例的 ivar 可能是弱引用 / 已释放的对象：先过一次校验
                     * （奇地址、小整数、元类一律丢掉），别拿野指针去 isKindOfClass。 */
                    id v = AevonVerifiedObject(object_getIvar(node, ivars[i]));
                    if (v == nil) { continue; }
                    NSString *vk = AevonPtrKey(v);
                    if (![seen containsObject:vk]) { [out addObject:v]; }
                    if (AevonIsContainerObject(v)) {
                        /* 关键一步：字典 / 数组直接摊开 —— scene manager 就在这里 */
                        for (id it in AevonContainerPeek(v)) {
                            NSString *ik = AevonPtrKey(it);
                            if (![seen containsObject:ik]) { [out addObject:it]; }
                            [next addObject:it];
                        }
                    } else if (!AevonGraphSkipClass(object_getClass(v))) {
                        [next addObject:v];
                    }
                }
                free(ivars);
            } @catch (NSException *e) { }
        }
        layer = next;
        if (layer.count == 0) { break; }
    }
    return out;
}

NSString *AevonIvarDumpReport(id obj, int limit) {
    if (obj == nil || limit <= 0) { return @""; }
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class c = object_getClass(obj);
        if (c == Nil || class_isMetaClass(c)) { return @""; }
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        if (ivars == NULL) { return @""; }
        for (unsigned int i = 0; i < count && (int)out.count < limit; i++) {
            Ivar iv = ivars[i];
            const char *nm = ivar_getName(iv);
            if (nm == NULL) { continue; }
            NSString *name = [NSString stringWithUTF8String:nm];
            const char *enc = ivar_getTypeEncoding(iv);
            NSString *val = @"?";
            if (enc != NULL && enc[0] == '@') {
                id v = AevonVerifiedObject(object_getIvar(obj, iv));
                if (v == nil) {
                    val = @"nil";
                } else if (AevonIsContainerObject(v)) {
                    NSUInteger n = 0;
                    @try {
                        if ([v isKindOfClass:[NSDictionary class]]) { n = [(NSDictionary *)v count]; }
                        else if ([v isKindOfClass:[NSSet class]]) { n = [(NSSet *)v count]; }
                        else if ([v isKindOfClass:[NSOrderedSet class]]) { n = [(NSOrderedSet *)v count]; }
                        else { n = [(NSArray *)v count]; }
                    } @catch (NSException *e) { }
                    Class ic = Nil;
                    NSArray *peek = AevonContainerPeek(v);
                    if (peek.count > 0) { ic = object_getClass(peek.firstObject); }
                    const char *icn = ic ? class_getName(ic) : NULL;
                    val = [NSString stringWithFormat:@"容器(%lu)%@",
                           (unsigned long)n, icn ? [NSString stringWithUTF8String:icn] : @"?"];
                } else {
                    const char *cn = class_getName(object_getClass(v));
                    val = cn ? [NSString stringWithUTF8String:cn] : @"?";
                }
            } else if (enc != NULL) {
                val = [NSString stringWithUTF8String:enc];
            }
            if (name.length > 0) {
                [out addObject:[NSString stringWithFormat:@"%@=%@", name, val]];
            }
        }
        free(ivars);
    } @catch (NSException *e) { }
    return out.count ? [out componentsJoinedByString:@","] : @"";
}

#pragma mark - 文件式存活登记

void AevonGuardAlivePublishFile(NSString *bundleID) {
    if (bundleID.length == 0) { return; }
    @try {
        NSString *path = [@"/var/mobile/Aevon.alive." stringByAppendingString:bundleID];
        NSString *body = [NSString stringWithFormat:@"%d", (int)getpid()];
        [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) { }
}

int AevonGuardAliveFileState(NSString *bundleID) {
    if (bundleID.length == 0) { return 0; }
    @try {
        NSString *path = [@"/var/mobile/Aevon.alive." stringByAppendingString:bundleID];
        NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (s.length == 0) { return 0; }
        int pid = s.intValue;
        if (pid <= 0) { return 0; }
        /* 进程还活着才算数（App 被杀掉后旧文件不该让人误判） */
        if (kill((pid_t)pid, 0) != 0 && errno != EPERM) { return 0; }
        return pid;
    } @catch (NSException *e) { return 0; }
}

#pragma mark - V0.0.80：provider 能力探测 / 类方法表打印

/* Aevon(72) 日志：provider 已经是 `SBMainDisplaySceneManager`（对象图命中），
 * 但 SBDeviceApplicationSceneEntity 的三个 init 全部返回 nil。返回 nil 几乎必然意味着
 * init 内部走 `-sceneHandleForSceneIdentity:` 拿不到 handle —— 也就是
 * `-sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:` 返回了 nil。
 * 为什么 nil？两种可能：
 *   ① 这个 App 是单场景 App（Info.plist 没有 UIApplicationSupportsMultipleScenes），
 *      已经有 primary scene，`createPrimaryIfRequired:YES` 也不给第二个；
 *   ② sceneSessionRole 传错（要的是 @"UIWindowSceneSessionRoleApplication"）。
 * 这个函数把整条链的实际返回值原样打出来，下一轮能一眼定死是哪种。 */
NSString *AevonProviderProbeReport(id provider, id app) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    @try {
        if (provider == nil) { return @"provider=nil"; }
        if (app == nil) { [out addObject:@"app=nil"]; }
        /* ① identity 链 */
        NSArray<NSString *> *idSels = @[@"sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:",
                                        @"_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:"];
        for (NSString *name in idSels) {
            SEL sel = NSSelectorFromString(name);
            if (![provider respondsToSelector:sel]) {
                [out addObject:[NSString stringWithFormat:@"%@=不支持", [name componentsSeparatedByString:@":"][0]]];
                continue;
            }
            for (NSNumber *flag in @[@NO, @YES]) {
                id identity = nil;
                @try {
                    id (*fn)(id, SEL, id, BOOL, id) = (void *)objc_msgSend;
                    identity = fn(provider, sel, app, (BOOL)flag.boolValue,
                                  @"UIWindowSceneSessionRoleApplication");
                } @catch (NSException *e) { identity = nil; }
                NSString *cls = identity ? NSStringFromClass([identity class]) : @"nil";
                [out addObject:[NSString stringWithFormat:@"%@(create=%d)=%@",
                                [name componentsSeparatedByString:@":"][0],
                                flag.boolValue ? 1 : 0, cls]];
                /* ② 拿到 identity 就继续探 handle */
                if (identity != nil) {
                    for (NSString *hsel in @[@"sceneHandleForSceneIdentity:",
                                             @"existingSceneHandleForSceneIdentity:",
                                             @"sceneHandleForIdentity:"]) {
                        SEL hs = NSSelectorFromString(hsel);
                        if (![provider respondsToSelector:hs]) { continue; }
                        id handle = nil;
                        @try {
                            id (*hfn)(id, SEL, id) = (void *)objc_msgSend;
                            handle = hfn(provider, hs, identity);
                        } @catch (NSException *e) { handle = nil; }
                        [out addObject:[NSString stringWithFormat:@"%@=%@",
                                        [hsel componentsSeparatedByString:@":"][0],
                                        handle ? NSStringFromClass([handle class]) : @"nil"]];
                    }
                }
            }
        }
        /* ③ App 自身的场景标识（判断「是不是已经有 primary」） */
        for (NSString *sel in @[@"primarySceneIdentifier", @"sceneIdentifier", @"bundleIdentifier",
                                @"persistentIdentifier"]) {
            SEL s = NSSelectorFromString(sel);
            if (app == nil || ![app respondsToSelector:s]) { continue; }
            id v = nil;
            @try { v = ((id (*)(id, SEL))objc_msgSend)(app, s); } @catch (NSException *e) { v = nil; }
            if ([v isKindOfClass:[NSString class]]) {
                [out addObject:[NSString stringWithFormat:@"app.%@=%@", sel, v]];
            } else if (v != nil) {
                [out addObject:[NSString stringWithFormat:@"app.%@=<%@>", sel, NSStringFromClass([v class])]];
            }
        }
        /* ④ 多场景支持（App 的 Info.plist 声明）—— 单场景 App 建不了第二个 scene。
         * 注意：不能用 `[NSBundle mainBundle]`（那是 SpringBoard 自己的 Info.plist），
         * 只能顺着 SBApplication 拿它自己的 bundle。 */
        @try {
            id multi = nil;
            if (app != nil && [app respondsToSelector:@selector(bundle)]) {
                id b = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundle));
                if ([b isKindOfClass:[NSBundle class]]) {
                    multi = ((NSBundle *)b).infoDictionary[@"UIApplicationSceneManifest"][@"UIApplicationSupportsMultipleScenes"];
                }
            }
            if (multi == nil) { multi = @"未声明(默认NO)"; }
            [out addObject:[NSString stringWithFormat:@"多场景声明=%@", multi]];
        } @catch (NSException *e) {
            [out addObject:@"多场景声明=读取失败"];
        }
    } @catch (NSException *e) {
        [out addObject:[NSString stringWithFormat:@"异常=%@", e.reason ?: @"?"]];
    }
    return [out componentsJoinedByString:@","];
}

/* 类方法表（按关键字过滤）—— 下一轮从 SBMainDisplaySceneManager 上直接找
 * 「给某个 App 建新场景」的官方 API，不再靠猜属性名。只读，不改任何东西。 */
NSString *AevonClassMethodDump(NSString *clsName, NSString *keywordCSV) {
    @try {
        Class cls = NSClassFromString(clsName);
        if (cls == Nil) { return @"类不存在"; }
        NSArray<NSString *> *keywords = [keywordCSV componentsSeparatedByString:@","];
        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        if (methods != NULL) {
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                for (NSString *kw in keywords) {
                    if (kw.length > 0 && [name rangeOfString:kw].location != NSNotFound) {
                        [hits addObject:name];
                        break;
                    }
                }
            }
            free(methods);
        }
        /* 超类也扫一遍（SBSceneManager 的创建 API 在父类上） */
        Class super_ = class_getSuperclass(cls);
        if (super_ != Nil && super_ != [NSObject class]) {
            unsigned int sc = 0;
            Method *sm = class_copyMethodList(super_, &sc);
            if (sm != NULL) {
                for (unsigned int i = 0; i < sc; i++) {
                    NSString *name = NSStringFromSelector(method_getName(sm[i]));
                    for (NSString *kw in keywords) {
                        if (kw.length > 0 && [name rangeOfString:kw].location != NSNotFound) {
                            [hits addObject:[@"父:" stringByAppendingString:name]];
                            break;
                        }
                    }
                }
                free(sm);
            }
        }
        return hits.count ? [hits componentsJoinedByString:@" | "] : @"无命中";
    } @catch (NSException *e) {
        return @"异常";
    }
}
