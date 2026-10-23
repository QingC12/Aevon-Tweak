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
