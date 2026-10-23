#import "AevonSceneShim.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

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

/// 尽力把一个 displayConfiguration 的逻辑尺寸改成 target。
/// 成功返回新对象（调用方负责 setDisplayConfiguration: 下发），失败返回 nil。
static id AevonResizeDisplayConfiguration(id oldDC, CGSize target, int *outBits) {
    @try {
        Class cls = NSClassFromString(@"UIDisplayConfiguration");
        if (cls == Nil) { return nil; }

        /* 策略 1：从旧配置拷贝（保留 displayID / mode 等现场），再 KVC 改尺寸 */
        id candidate = nil;
        if (oldDC != nil) {
            SEL copySel = NSSelectorFromString(@"initWithDisplayConfiguration:");
            if ([cls instancesRespondToSelector:copySel]) {
                id (*allocFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id raw = allocFn(cls, NSSelectorFromString(@"alloc"));
                id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                candidate = initFn(raw, copySel, oldDC);
            }
        }
        /* 策略 2：全新配置（拷贝失败 / 没有旧配置时） */
        if (candidate == nil) {
            SEL initSel = NSSelectorFromString(@"init");
            if ([cls instancesRespondToSelector:initSel]) {
                id (*allocFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id raw = allocFn(cls, NSSelectorFromString(@"alloc"));
                id (*initFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                candidate = initFn(raw, initSel);
            }
        }
        if (candidate == nil) { return nil; }

        NSValue *boxed = [NSValue valueWithCGSize:target];
        /* KVC 写尺寸：Foundation 对结构体 ivar 支持 NSValue 直写（_size / size 回退）。
         * 只读属性也会因为 ivar 回退而成功 —— 写不进就 @catch 返回 nil。 */
        SEL setSel = NSSelectorFromString(@"setSize:");
        if ([candidate respondsToSelector:setSel]) {
            void (*fn)(id, SEL, CGSize) = (void (*)(id, SEL, CGSize))objc_msgSend;
            fn(candidate, setSel, target);
            *outBits |= 0x4;
            return candidate;
        }
        @try {
            [candidate setValue:boxed forKey:@"size"];
            *outBits |= 0x4;
            return candidate;
        } @catch (NSException *unused) {}
        SEL setPointsSel = NSSelectorFromString(@"setSizeInPoints:");
        if ([candidate respondsToSelector:setPointsSel]) {
            void (*fn)(id, SEL, CGSize) = (void (*)(id, SEL, CGSize))objc_msgSend;
            fn(candidate, setPointsSel, target);
            *outBits |= 0x8;
            return candidate;
        }
        @try {
            [candidate setValue:boxed forKey:@"sizeInPoints"];
            *outBits |= 0x8;
            return candidate;
        } @catch (NSException *unused) {}
        if (candidate != nil && candidate != oldDC) { candidate = nil; }
        return nil;
    } @catch (NSException *exception) {
        return nil;
    }
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

        /* 杠杆 ①：frame（V55 已证有效，只是不够） */
        if (AevonSettingsSetFrame(mutable, CGRectMake(0, 0, size.width, size.height))) {
            bits |= 0x1;
        }

        /* 杠杆 ②：displayConfiguration 随帧一起下发（Mango 实证的关键差异） */
        id oldDC = AevonSceneDisplayConfiguration(mutable);
        if (oldDC != nil) { bits |= 0x2; }
        id newDC = AevonResizeDisplayConfiguration(oldDC, size, &bits);
        if (newDC != nil) {
            SEL setDCSel = NSSelectorFromString(@"setDisplayConfiguration:");
            if ([mutable respondsToSelector:setDCSel]) {
                void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                fn(mutable, setDCSel, newDC);
                bits |= 0x10;
            }
        }

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
