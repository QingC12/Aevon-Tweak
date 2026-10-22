#import "AevonPresenterShim.h"
#import <objc/message.h>

/*
 * 场景呈现垫片（Objective-C，异常安全）。
 *
 * 为什么用 ObjC：
 * 1. `uiPresentationManager` / `createPresenterWithIdentifier:` / `modifyPresentationContext:`
 *    全是 UIKit 私有 API，没有可用头文件；用 objc_msgSend 强类型直调最省事。
 * 2. `_UIScenePresenterOwner` 未 invalidate 就释放会抛 ObjC 异常
 *    （V0.0.9 就是这样把 SpringBoard 打注销的）。Swift 捕获不到 ObjC 异常，
 *    所以整条链路必须放在 @try/@catch 内。
 */

typedef id (*AevonIdFn0)(id, SEL);
typedef id (*AevonIdFn1)(id, SEL, id);
typedef void (*AevonVoidFn0)(id, SEL);
typedef void (*AevonVoidFn1)(id, SEL, id);
typedef void (*AevonVoidFnInt1)(id, SEL, NSInteger);
typedef void (*AevonVoidFnBlock1)(id, SEL, void (^)(id));

id AevonPresenterCreate(id scene, NSString *identifier) {
    @try {
        if (scene == nil || identifier.length == 0) return nil;

        SEL managerSelector = NSSelectorFromString(@"uiPresentationManager");
        if (![scene respondsToSelector:managerSelector]) return nil;
        id manager = ((AevonIdFn0)objc_msgSend)(scene, managerSelector);
        if (manager == nil) return nil;

        SEL createSelector = NSSelectorFromString(@"createPresenterWithIdentifier:");
        if (![manager respondsToSelector:createSelector]) return nil;
        id presenter = ((AevonIdFn1)objc_msgSend)(manager, createSelector, identifier);
        if (presenter == nil) return nil;

        // appearanceStyle = 2：只要 App 自己的内容，不要系统给它加的装饰
        SEL modifySelector = NSSelectorFromString(@"modifyPresentationContext:");
        if ([presenter respondsToSelector:modifySelector]) {
            void (^configure)(id) = ^(id context) {
                @try {
                    SEL styleSelector = NSSelectorFromString(@"setAppearanceStyle:");
                    if ([context respondsToSelector:styleSelector]) {
                        ((AevonVoidFnInt1)objc_msgSend)(context, styleSelector, 2);
                    }
                } @catch (NSException *exception) {
                    // 外观设置失败不影响呈现
                }
            };
            ((AevonVoidFnBlock1)objc_msgSend)(presenter, modifySelector, configure);
        }

        SEL activateSelector = NSSelectorFromString(@"activate");
        if ([presenter respondsToSelector:activateSelector]) {
            ((AevonVoidFn0)objc_msgSend)(presenter, activateSelector);
        }
        return presenter;
    } @catch (NSException *exception) {
        return nil;
    }
}

id AevonPresenterView(id presenter) {
    @try {
        if (presenter == nil) return nil;
        SEL selector = NSSelectorFromString(@"presentationView");
        if (![presenter respondsToSelector:selector]) return nil;
        return ((AevonIdFn0)objc_msgSend)(presenter, selector);
    } @catch (NSException *exception) {
        return nil;
    }
}

void AevonPresenterDestroy(id presenter) {
    @try {
        if (presenter == nil) return;
        SEL deactivateSelector = NSSelectorFromString(@"deactivate");
        if ([presenter respondsToSelector:deactivateSelector]) {
            ((AevonVoidFn0)objc_msgSend)(presenter, deactivateSelector);
        }
    } @catch (NSException *exception) {
        // 忽略：继续尝试 invalidate
    }
    @try {
        if (presenter == nil) return;
        SEL invalidateSelector = NSSelectorFromString(@"invalidate");
        if ([presenter respondsToSelector:invalidateSelector]) {
            ((AevonVoidFn0)objc_msgSend)(presenter, invalidateSelector);
        }
    } @catch (NSException *exception) {
        // 忽略：不能让异常冒到 SpringBoard
    }
}
