#import <Foundation/Foundation.h>

/// 场景呈现垫片（Objective-C，异常安全）。
///
/// iOS 15–17 把「别的 App 的实时画面」放进自己的窗口里，正确路径是向场景的
/// `uiPresentationManager` 申请 presenter，而不是自己造图层宿主视图：
///   presenter = [scene.uiPresentationManager createPresenterWithIdentifier:@"xxx"];
///   [presenter modifyPresentationContext:^(ctx){ ctx.appearanceStyle = 2; }];
///   [presenter activate];
///   [view addSubview:presenter.presentationView];
///
/// 所有私有调用都包在 @try/@catch 里：Swift 无法捕获 ObjC 异常，
/// 一旦抛出就会直接杀掉 SpringBoard。这里任何失败只返回 nil。

/// 为场景创建并激活 presenter；失败返回 nil。
id AevonPresenterCreate(id scene, NSString *identifier);

/// 取 presenter 的呈现视图；失败返回 nil。
id AevonPresenterView(id presenter);

/// 释放 presenter：必须先 deactivate 再 invalidate，否则 UIKit 抛
/// `_UIScenePresenterOwner ... must be invalidated before it can be deallocated`。
void AevonPresenterDestroy(id presenter);
