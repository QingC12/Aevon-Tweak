#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

/*
 * Aevon 设置页控制器
 * =====================================================================
 * V0.0.3：entry.plist 的 detail 指向系统 PSListController（不属于本 bundle，
 *         取不到 Root.plist）→ 点击设置项闪退。
 * V0.0.4：改为 bundle 内的 AevonRootListController，不再闪退，但页面空白。
 * V0.0.5：修复空白。
 *
 * 空白根因（V0.0.4）：
 *   PSListController 把列表数据缓存在实例变量 _specifiers 里，表格数据源
 *   读的是这个 ivar，而不是每次调用 -specifiers。V0.0.4 的实现先调
 *   [super specifiers]（此时 bundle/plist 还没就绪，返回空数组并被写进
 *   _specifiers），随后自己 loadSpecifiersFromPlistName 得到的内容只做了
 *   return，没有写回 _specifiers → 数据源永远看到空数组 → 页面空白。
 *
 * V0.0.5 做法（三重来源，从可靠到兜底）：
 *   1) 先读 _specifiers（通过 runtime 找 ivar，不在编译期声明，避免依赖
 *      私有类的内存布局）；
 *   2) 自己用 [NSBundle bundleForClass:self] 定位包内 Root.plist，逐条把
 *      items 转成 PSSpecifier（完全不依赖 PSListController 的私有加载路径，
 *      roothide 下也稳）；
 *   3) 若 Root.plist 读不到，用代码硬编码同样的开关，保证绝不空白、绝不崩。
 *   最后无论哪条路径，都把结果写回 _specifiers（CFRetain 保活），
 *   让表格数据源真正看到这些 specifier。
 *
 * 安全约束：任何私有调用都包 @try，任何分支都不向系统返回 nil。
 * =====================================================================
 */

/* theos 的 iPhoneOS16.5.sdk 只有 Preferences.tbd、没有头文件，这里手工声明最小接口 */
@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (id)readPreferenceValue:(id)specifier;
@end

/*
 * PSSpecifier 的属性读写。
 * 注意：不能在 NSObject 上声明 -setProperty:forKey: 类别 —— UIKit 里存在多个
 * 同名不同签名的实现，clang 会报 -Wobjc-multiple-method-names（本工程 -Werror）。
 * 这里全部走 runtime 直调，既避开重名解析，也不依赖私有头文件。
 */
static void AevonSetProperty(id spec, id value, NSString *key) {
    if (spec == nil || key == nil) return;
    SEL sel = sel_registerName("setProperty:forKey:");
    if (![spec respondsToSelector:sel]) return;
    typedef void (*SetPropertyFn)(id, SEL, id, NSString *);
    SetPropertyFn fn = (SetPropertyFn)[spec methodForSelector:sel];
    if (fn == NULL) return;
    @try { fn(spec, sel, value, key); } @catch (NSException *exception) {}
}

static NSString *const AevonPrefsDomain = @"com.Aevon";
/* PSSwitchCell 的 cell 类型值（Preferences 框架常量，多年未变） */
#define AEVON_CELL_SWITCH 6

#pragma mark - _specifiers 读写（runtime，不依赖 ivar 声明）

static Ivar AevonFindSpecifiersIvar(id object) {
    if (object == nil) return NULL;
    for (Class cls = object_getClass(object); cls != Nil; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, "_specifiers");
        if (ivar != NULL) return ivar;
    }
    return NULL;
}

static NSArray *AevonCachedSpecifiers(id object) {
    Ivar ivar = AevonFindSpecifiersIvar(object);
    if (ivar == NULL) return nil;
    id value = object_getIvar(object, ivar);
    if ([value isKindOfClass:[NSArray class]] && [value count] > 0) {
        return (NSArray *)value;
    }
    return nil;
}

static void AevonStoreSpecifiers(id object, NSArray *list) {
    Ivar ivar = AevonFindSpecifiersIvar(object);
    if (ivar == NULL) return;
    /* object_setIvar 不做引用计数管理，这里显式持有，避免数组被提前释放 */
    object_setIvar(object, ivar, (__bridge id)CFBridgingRetain(list));
}

#pragma mark - PSSpecifier 构造（全部走 runtime，避免链接私有符号）

static id AevonNewSpecifier(NSString *label,
                            id target,
                            SEL setter,
                            SEL getter,
                            NSInteger cell) {
    Class specifierClass = objc_getClass("PSSpecifier");
    if (specifierClass == Nil) return nil;
    SEL maker = sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
    Class meta = object_getClass((id)specifierClass);
    if (meta == Nil || !class_respondsToSelector(meta, maker)) return nil;

    typedef id (*MakerFn)(id, SEL, NSString *, id, SEL, SEL, Class, NSInteger, Class);
    MakerFn fn = (MakerFn)class_getMethodImplementation(meta, maker);
    if (fn == NULL) return nil;

    @try {
        return fn((id)specifierClass, maker, label ?: @"", target, setter, getter, Nil, cell, Nil);
    } @catch (NSException *exception) {
        return nil;
    }
}

static id AevonNewGroup(NSString *title, NSString *footer) {
    Class specifierClass = objc_getClass("PSSpecifier");
    if (specifierClass == Nil) return nil;
    Class meta = object_getClass((id)specifierClass);
    if (meta == Nil) return nil;

    id spec = nil;
    SEL maker = sel_registerName("groupSpecifierWithName:");
    if (class_respondsToSelector(meta, maker)) {
        typedef id (*GroupFn)(id, SEL, NSString *);
        GroupFn fn = (GroupFn)class_getMethodImplementation(meta, maker);
        if (fn != NULL) {
            @try { spec = fn((id)specifierClass, maker, title ?: @""); } @catch (NSException *e) { spec = nil; }
        }
    }
    if (spec == nil) {
        SEL empty = sel_registerName("emptyGroupSpecifier");
        if (class_respondsToSelector(meta, empty)) {
            typedef id (*EmptyFn)(id, SEL);
            EmptyFn fn = (EmptyFn)class_getMethodImplementation(meta, empty);
            if (fn != NULL) {
                @try { spec = fn((id)specifierClass, empty); } @catch (NSException *e) { spec = nil; }
            }
            if (spec != nil && title.length > 0) {
                AevonSetProperty(spec, title, @"label");
            }
        }
    }
    if (spec != nil && footer.length > 0) {
        AevonSetProperty(spec, footer, @"footerText");
    }
    return spec;
}

static id AevonNewSwitch(NSString *label, id target, NSString *key, id defaultValue) {
    id spec = AevonNewSpecifier(label,
                                target,
                                @selector(setPreferenceValue:specifier:),
                                @selector(readPreferenceValue:),
                                AEVON_CELL_SWITCH);
    if (spec == nil) return nil;
    @try {
        if (key.length > 0) {
            AevonSetProperty(spec, key, @"key");
            AevonSetProperty(spec, key, @"id");
        }
        AevonSetProperty(spec, AevonPrefsDomain, @"defaults");
        if (defaultValue != nil) AevonSetProperty(spec, defaultValue, @"default");
    } @catch (NSException *exception) {
        return nil;
    }
    return spec;
}

#pragma mark - 来源 2：从包内 Root.plist 构建

static NSArray *AevonBuildFromPlist(id target, NSBundle *bundle) {
    if (bundle == nil) return nil;
    NSString *path = [bundle pathForResource:@"Root" ofType:@"plist"];
    if (path.length == 0) return nil;

    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![root isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *items = root[@"items"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return nil;

    NSMutableArray *result = [NSMutableArray array];
    for (id raw in items) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *item = (NSDictionary *)raw;
        NSString *cell = item[@"cell"];
        NSString *label = item[@"label"] ?: item[@"title"] ?: @"";

        if ([cell isEqualToString:@"PSGroupCell"]) {
            id group = AevonNewGroup(label, item[@"footerText"] ?: item[@"footer"]);
            if (group != nil) [result addObject:group];
        } else if ([cell isEqualToString:@"PSSwitchCell"]) {
            NSString *key = item[@"key"];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
            id def = item[@"default"];
            id spec = AevonNewSwitch(label, target, key, def);
            if (spec != nil) [result addObject:spec];
        }
    }
    return result.count > 0 ? result : nil;
}

#pragma mark - 来源 3：代码硬编码兜底（Root.plist 读不到时用）

static NSArray *AevonBuildFallback(id target) {
    NSMutableArray *result = [NSMutableArray array];

    id group1 = AevonNewGroup(@"Aevon 分屏",
                              @"V0.0.5 最小浮窗版（纯 arm64e / roothide）。所有功能只在本页开关，无需终端/SSH。日志文件：/var/mobile/Aevon.log（Filza 可见）。若 SpringBoard 反复异常，插件会自动禁用，可在本页重新开启。");
    if (group1 != nil) [result addObject:group1];
    id s1 = AevonNewSwitch(@"启用插件", target, @"Enabled", @NO);
    if (s1 != nil) [result addObject:s1];
    id s2 = AevonNewSwitch(@"窗口保活（保持前台）", target, @"KeepAlive", @YES);
    if (s2 != nil) [result addObject:s2];

    id group2 = AevonNewGroup(@"安全与日志",
                              @"「开机崩溃保护」：每次加载写入 loading 状态，SpringBoard 稳定 20 秒后标记 healthy；若下次启动发现上次仍是 loading，则自动禁用插件，阻断崩溃死循环。");
    if (group2 != nil) [result addObject:group2];
    id s3 = AevonNewSwitch(@"开机崩溃保护", target, @"CrashGuard", @YES);
    if (s3 != nil) [result addObject:s3];
    id s4 = AevonNewSwitch(@"写日志文件（/var/mobile/Aevon.log）", target, @"LogEnabled", @YES);
    if (s4 != nil) [result addObject:s4];

    return result.count > 0 ? result : nil;
}

#pragma mark - 控制器

@interface AevonRootListController : PSListController
@end

@implementation AevonRootListController

- (NSArray *)specifiers {
    /* 1) 已有缓存直接返回，避免每次刷新重建 */
    NSArray *cached = AevonCachedSpecifiers(self);
    if (cached != nil) return cached;

    /* 2) 先试系统加载（bundle 就绪时这条最原生）；失败不写入缓存 */
    NSArray *list = nil;
    @try {
        list = [self loadSpecifiersFromPlistName:@"Root" target:self];
    } @catch (NSException *exception) {
        list = nil;
    }
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) list = nil;

    /* 3) 自己从本 bundle 的 Root.plist 构建（不依赖私有加载路径） */
    if (list == nil) {
        NSBundle *bundle = nil;
        @try { bundle = [NSBundle bundleForClass:[self class]]; } @catch (NSException *e) { bundle = nil; }
        if (bundle == nil) bundle = [NSBundle mainBundle];
        list = AevonBuildFromPlist(self, bundle);
    }

    /* 4) 硬编码兜底：宁可少两个分组说明，也绝不空白 */
    if (list == nil) list = AevonBuildFallback(self);

    /* 5) 写回 _specifiers —— 表格数据源读的是它，这一步是 V0.0.5 的关键 */
    if (list.count > 0) AevonStoreSpecifiers(self, list);

    return list ?: @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.title.length == 0) self.title = @"Aevon";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    /*
     * 系统在本控制器 setSpecifier: 时可能已用空数组初始化过缓存，
     * 这里让 PSListController 重新走一遍 -specifiers（此时会命中我们写回的缓存），
     * 确保表格渲染的是最新结果。任何异常都不允许冒泡。
     */
    @try {
        if ([self respondsToSelector:@selector(reloadSpecifiers)]) {
            [self reloadSpecifiers];
        }
    } @catch (NSException *exception) {
    }
}

@end
