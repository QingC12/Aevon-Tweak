#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/*
 * 本 SDK（theos 的 iPhoneOS16.5.sdk）只提供 Preferences.tbd，没有 Preferences 头文件，
 * 因此这里手工声明 PSListController 的最小接口。
 *
 * 关键：只声明/调用方法，不声明也不访问任何实例变量（不碰 _specifiers），
 * 从而不依赖真实类的内存布局，兼容各 iOS 版本。
 */
@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

/*
 * 为什么必须要这个子类（V0.0.3「点击设置项闪退」的根因）：
 * 旧版 entry.plist 的 detail 直接写系统的 PSListController。
 * 该控制器不属于本 bundle，取不到 AevonPrefs.bundle 内的 Root.plist，
 * specifiers 为 nil，设置进程在构建列表时崩溃。
 * 定义在 bundle 内自己的子类，才能让 +bundleForClass: 归属到本 bundle。
 */
@interface AevonRootListController : PSListController
@end

@implementation AevonRootListController

- (NSArray *)specifiers {
    NSArray *list = nil;
    @try {
        list = [super specifiers];
    } @catch (NSException *exception) {
        list = nil;
    }
    if (list.count > 0) {
        return list;
    }

    @try {
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (loaded) {
            return loaded;
        }
    } @catch (NSException *exception) {
        // 加载失败走下面的空数组兜底
    }

    // 兜底必须返回空数组而不是 nil：宁可显示空页面，也不能让设置进程崩溃
    return @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.title.length == 0) {
        self.title = @"Aevon";
    }
}

@end
