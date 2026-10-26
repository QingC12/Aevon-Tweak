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
static NSString *const AevonPrefsDomain = @"com.Aevon";

static void AevonSetProperty(id spec, id value, NSString *key) {
    if (spec == nil || key == nil) return;
    SEL sel = sel_registerName("setProperty:forKey:");
    if (![spec respondsToSelector:sel]) return;
    typedef void (*SetPropertyFn)(id, SEL, id, NSString *);
    SetPropertyFn fn = (SetPropertyFn)[spec methodForSelector:sel];
    if (fn == NULL) return;
    @try { fn(spec, sel, value, key); } @catch (NSException *exception) {}
}

/* 读回 specifier 的属性（同一套 runtime 直调，避开私有头文件） */
static id AevonGetProperty(id spec, NSString *key) {
    if (spec == nil || key == nil) return nil;
    SEL sel = sel_registerName("propertyForKey:");
    if (![spec respondsToSelector:sel]) return nil;
    typedef id (*GetPropertyFn)(id, SEL, NSString *);
    GetPropertyFn fn = (GetPropertyFn)[spec methodForSelector:sel];
    if (fn == NULL) return nil;
    @try { return fn(spec, sel, key); } @catch (NSException *exception) { return nil; }
    return nil;
}

/*
 * 读偏好里的数值（V0.0.28）。
 * 根因：PSSliderCell 初始化滑块位置时只看 specifier 的 "default"，
 * 不会走 readPreferenceValue: —— 于是三个触发区滑杆一进页面全停在最左端（0），
 * 用户一碰就把 0 写回偏好，触发条就跑到屏幕最顶部、高度/宽度也变成最小值。
 * 现在构造 specifier 时直接用**已存储的值**当 default，滑块一进来就在正确位置。
 */
static NSNumber *AevonPrefsNumber(NSString *key) {
    if (key.length == 0) return nil;
    CFStringRef domain = (__bridge CFStringRef)AevonPrefsDomain;
    CFPreferencesAppSynchronize(domain);
    CFTypeRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain);
    if (raw == NULL) return nil;
    NSNumber *number = nil;
    CFTypeID type = CFGetTypeID(raw);
    if (type == CFNumberGetTypeID()) {
        number = (__bridge_transfer NSNumber *)raw;
    } else if (type == CFStringGetTypeID()) {
        NSString *text = (__bridge_transfer NSString *)raw;
        number = @([text doubleValue]);
    } else {
        CFRelease(raw);
    }
    return number;
}

/*
 * V0.0.28：滑条同步的诊断输出。
 * 这个 ASCII 字面量同时是 CI 的构建后校验标记（swift/objc 的方法名不在 __cstring 里，
 * 只有这种字面量能被 `strings` 扫到）。
 */
static void AevonLogPrefsSync(void) {
    NSString *marker = @"AevonSliderSyncV28";
    if (marker.length == 0) { NSLog(@"%@", marker); }
    NSLog(@"[Aevon] 触发区滑条已按存储值校正（%@）", marker);
}

/* PSSwitchCell 的 cell 类型值（Preferences 框架常量，多年未变） */
#define AEVON_CELL_SWITCH 6
/* PSSliderCell 的 cell 类型值（V0.0.25 新增：圆盘触发区域的位置 / 宽度 / 高度） */
#define AEVON_CELL_SLIDER 5
/* PSButtonCell 的 cell 类型值（V0.0.27 新增：「编辑圆盘 App」入口按钮） */
#define AEVON_CELL_BUTTON 13

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

/*
 * 滑杆（V0.0.25）。
 * 需要同时给出 minValue / maxValue / default 三个数值属性 —— Preferences 框架
 * 在不同 iOS 版本上分别读 "minValue"/"maxValue"，旧版本还会读 "min"/"max"，
 * 这里两套都写，免得出现「滑杆拖到头数值不变」或「滑杆范围是 0~1」。
 */
static id AevonNewSlider(NSString *label,
                         id target,
                         NSString *key,
                         double minValue,
                         double maxValue,
                         double defaultValue) {
    id spec = AevonNewSpecifier(label,
                                target,
                                @selector(setPreferenceValue:specifier:),
                                @selector(readPreferenceValue:),
                                AEVON_CELL_SLIDER);
    if (spec == nil) return nil;
    @try {
        if (key.length > 0) {
            AevonSetProperty(spec, key, @"key");
            AevonSetProperty(spec, key, @"id");
        }
        AevonSetProperty(spec, AevonPrefsDomain, @"defaults");
        AevonSetProperty(spec, @(minValue), @"minValue");
        AevonSetProperty(spec, @(maxValue), @"maxValue");
        AevonSetProperty(spec, @(minValue), @"min");
        AevonSetProperty(spec, @(maxValue), @"max");
        AevonSetProperty(spec, @(defaultValue), @"default");
        /* 右侧显示当前数值，用户才知道拖到了哪个百分比 / 多少 pt */
        AevonSetProperty(spec, @YES, @"showValue");
    } @catch (NSException *exception) {
        return nil;
    }
    return spec;
}

#pragma mark - 来源 2：从包内 Root.plist 构建
static NSArray *AevonBuildFromPlist(id target, NSBundle *bundle, NSString *plistName) {
    if (bundle == nil) return nil;
    NSString *name = plistName.length > 0 ? plistName : @"Root";
    NSString *path = [bundle pathForResource:name ofType:@"plist"];
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
            /* V0.2.9（AevonPrefsInfoV209）：开关的详细说明。
             * 放进 specifier 的 infoText 属性 —— 列表渲染时由
             * -tableView:willDisplayCell:forRowAtIndexPath: 在开关左侧补一个 ⓘ 按钮，
             * 点它弹 UIAlertController。开关名字本身只留短词。 */
            id info = item[@"infoText"];
            if (spec != nil && [info isKindOfClass:[NSString class]] && [info length] > 0) {
                AevonSetProperty(spec, info, @"infoText");
            }
            if (spec != nil) [result addObject:spec];
        } else if ([cell isEqualToString:@"PSSliderCell"] || [cell isEqualToString:@"PSTSliderCell"]) {
            NSString *key = item[@"key"];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
            double minValue = [item[@"minValue"] respondsToSelector:@selector(doubleValue)]
                ? [item[@"minValue"] doubleValue] : 0.0;
            double maxValue = [item[@"maxValue"] respondsToSelector:@selector(doubleValue)]
                ? [item[@"maxValue"] doubleValue] : 100.0;
            NSNumber *stored = AevonPrefsNumber(key);
            id initial = stored ?: item[@"default"];
            double defaultValue = [initial respondsToSelector:@selector(doubleValue)]
                ? [initial doubleValue] : minValue;
            if (maxValue <= minValue) maxValue = minValue + 1;
            if (defaultValue < minValue) defaultValue = minValue;
            if (defaultValue > maxValue) defaultValue = maxValue;
            id spec = AevonNewSlider(label, target, key, minValue, maxValue, defaultValue);
            if (spec != nil) [result addObject:spec];
        } else if ([cell isEqualToString:@"PSButtonCell"]) {
            /* V0.0.27：按钮式入口（用来推入自建的「圆盘 App」编辑器） */
            NSString *actionName = item[@"action"];
            SEL action = actionName.length > 0 ? NSSelectorFromString(actionName) : NULL;
            id spec = AevonNewSpecifier(label, target, action, nil, AEVON_CELL_BUTTON);
            if (spec != nil) {
                if (actionName.length > 0) {
                    AevonSetProperty(spec, actionName, @"buttonAction");
                }
                [result addObject:spec];
            }
        }
    }
    return result.count > 0 ? result : nil;
}

#pragma mark - 来源 3：代码硬编码兜底（Root.plist 读不到时用）

static NSArray *AevonBuildFallback(id target) {
    NSMutableArray *result = [NSMutableArray array];

    id group1 = AevonNewGroup(@"Aevon 分屏",
                              @"所有功能只在本页开关，无需终端/SSH。"
                              @"用法：打开「启用插件」→ 注销 → 在屏幕右边缘的触发区向左滑 → 弹出圆盘 → 点图标开窗。"
                              @"桌面上只会有一个浮窗，再点别的 App 会直接换成它（AevonSingleWindowV105）。"
                              @"全屏 App 内从右边缘向左滑同样可呼出（系统手势管线，App 不跟手）。"
                              @"日志文件：/var/mobile/Aevon.log（Filza 可见）。");
    if (group1 != nil) [result addObject:group1];
    id s1 = AevonNewSwitch(@"启用插件", target, @"Enabled", @NO);
    if (s1 != nil) [result addObject:s1];
    id s1a = AevonNewSwitch(@"边缘左滑呼出圆盘（热区 + 全屏 App 右缘）", target, @"EdgeGestureEnabled", @YES);
    if (s1a != nil) [result addObject:s1a];

    /* V0.0.30：一级页只放开关 + 细节入口；滑杆 / 圆盘 App 编辑在二级页 */
    /* V0.1.5（AevonNoSnapV105）：左右吸附开关已随吸附功能一起删除；
       「窗口保活」「强制前台保持」两个无实际作用的开关也删除
       （进程保活改为单窗恒开，走 RBSAssertion，不再让用户选）。*/
    id s2a = AevonNewSwitch(@"浮窗内可直接触摸操作（关掉=内容不接收触摸）", target, @"TouchEnabled", @YES);
    if (s2a != nil) [result addObject:s2a];
    id s2b = AevonNewSwitch(@"多任务卡片长按开窗（实验）", target, @"SwitcherLongPress", @NO);
    if (s2b != nil) [result addObject:s2b];
    id s3 = AevonNewSwitch(@"开机崩溃保护", target, @"CrashGuard", @YES);
    if (s3 != nil) [result addObject:s3];
    id s4 = AevonNewSwitch(@"写日志文件（/var/mobile/Aevon.log）", target, @"LogEnabled", @YES);
    if (s4 != nil) [result addObject:s4];
    /* V0.1.7（AevonProbeV107）：六组运行时探针。默认开，每次 SpringBoard 启动跑一轮，
       全部从 ObjC @try 里过 —— 探针只会「没结果」，不会再把 SpringBoard 带崩。*/
    id s5 = AevonNewSwitch(@"运行时探针（排错用，每次启动跑一轮六组）", target, @"ProbeV107", @YES);
    if (s5 != nil) [result addObject:s5];

    id groupDetail = AevonNewGroup(@"细节调整",
                                   @"触发条位置 / 宽度 / 高度、圆盘 App 编辑等都在二级页（AevonDetailPageV30）。");
    if (groupDetail != nil) [result addObject:groupDetail];
    id detailButton = AevonNewSpecifier(@"触发条 / 圆盘细节调整",
                                        target,
                                        NSSelectorFromString(@"aevonOpenDetail"),
                                        nil,
                                        AEVON_CELL_BUTTON);
    if (detailButton != nil) {
        AevonSetProperty(detailButton, @"aevonOpenDetail", @"buttonAction");
        [result addObject:detailButton];
    }

    return result.count > 0 ? result : nil;
}

/* V0.0.30：二级「细节调整」页的代码兜底（Detail.plist 读不到时用） */
static NSArray *AevonBuildFallbackDetail(id target) {
    NSMutableArray *result = [NSMutableArray array];

    id groupRing = AevonNewGroup(@"圆盘 App",
                                 @"圆盘里放哪些 App、按什么顺序排，都在这里改。");
    if (groupRing != nil) [result addObject:groupRing];
    id ringButton = AevonNewSpecifier(@"编辑圆盘 App（添加 / 排序）",
                                      target,
                                      NSSelectorFromString(@"aevonOpenRingEditor"),
                                      nil,
                                      AEVON_CELL_BUTTON);
    if (ringButton != nil) {
        AevonSetProperty(ringButton, @"aevonOpenRingEditor", @"buttonAction");
        [result addObject:ringButton];
    }

    id groupZone1 = AevonNewGroup(@"① 触发位置（底边锚定）",
                                  @"热区底边在屏幕高度的百分比。100% = 区底边贴住屏幕底部，"
                                  @"此时改「触发高度」触发条永远贴底、只向上伸展。");
    if (groupZone1 != nil) [result addObject:groupZone1];
    id z1 = AevonNewSlider(@"触发位置（区底边在屏幕高度 %）", target, @"RingTriggerY", 0, 100, 75);
    if (z1 != nil) [result addObject:z1];

    id groupZone2 = AevonNewGroup(@"② 触发宽度（横向）",
                                  @"热区从屏幕右边缘往左有多宽（pt）。默认 48，建议 30~60。");
    if (groupZone2 != nil) [result addObject:groupZone2];
    id z2 = AevonNewSlider(@"触发宽度（pt）", target, @"RingTriggerWidth", 18, 140, 48);
    if (z2 != nil) [result addObject:z2];

    id groupZone3 = AevonNewGroup(@"③ 触发高度（纵向）",
                                  @"热区从底边向上伸展的高度（pt）。默认 320，建议 240~420。");
    if (groupZone3 != nil) [result addObject:groupZone3];
    id z3 = AevonNewSlider(@"触发高度（pt）", target, @"RingTriggerHeight", 80, 900, 320);
    if (z3 != nil) [result addObject:z3];

    id resetButton = AevonNewSpecifier(@"恢复默认触发区域（75% / 48pt / 320pt）",
                                       target,
                                       NSSelectorFromString(@"aevonResetTriggerZone"),
                                       nil,
                                       AEVON_CELL_BUTTON);
    if (resetButton != nil) {
        AevonSetProperty(resetButton, @"aevonResetTriggerZone", @"buttonAction");
        [result addObject:resetButton];
    }

    /* V0.0.37：浮窗尺寸/位置设置项已移除 —— 浮窗几何改用 Stheno 式全局记忆
     * （medusaFrameLast 方案），拖动 / 缩放自动记住，无需设置项。 */

    return result.count > 0 ? result : nil;
}

#pragma mark - 控制器

@interface AevonRootListController : PSListController
/* V0.2.9（AevonPrefsInfoV209）：开关行内的 ⓘ 按钮与说明弹窗。
 * 声明在接口里，避免 @selector 在定义之前被用到时触发 -Wundeclared-selector（本工程 -Werror）。 */
- (void)aevonInfoTapped:(UIButton *)sender;
- (void)aevonPresentInfo:(NSString *)info title:(NSString *)title;
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
        list = AevonBuildFromPlist(self, bundle, @"Root");
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

/*
 * V0.0.26：滑杆每动一下都会走到这里。
 *
 * 用户 Aevon(19)：在设置里拖「触发位置 / 宽度 / 高度」，触发条不会跟着动。
 * 原因有两层：① SpringBoard 只在看门狗里每 3 秒重排一次；② 两个进程各有
 * CFPreferences 缓存，SpringBoard 可能还在读老值。
 * 这里在写回 defaults 之后立刻广播一条 Darwin 通知（跨进程、不带负载），
 * SpringBoard 收到后 synchronize + 比对指纹 + 重排，做到松手即见效果。
 */
- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    [super setPreferenceValue:value specifier:specifier];
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.aevon.prefschanged"),
                                             NULL, NULL, true);
    } @catch (NSException *exception) {
    }
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

#pragma mark - V0.0.27：滑杆拖动时实时生效

static char AevonSliderTagKey;

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    /*
     * 每次进页面：先按偏好重算一遍 specifier（这样三个滑杆的 default 就是真实存储值），
     * 再挂 target 并校正滑块位置。V0.0.28 之前滑块一律从 0 开始 —— 用户一碰就把 0
     * 写回偏好，触发条直接跑到屏幕最顶部（误以为「方向反了」）。
     */
    [self aevonHookSliders];
    [self aevonSyncAllSliders];
    AevonLogPrefsSync();
    /* V0.2.10（AevonGeomPreviewLiveV210）：一进「细节调整」页就请 SpringBoard 把
     * 触发区 / 接管带亮 3 秒 —— 用户不用先拖滑条才知道这两块现在长什么样。
     * 走一次性请求键（写当前时间戳），SB 侧看到数值变大就 preview 一次；
     * 不用 Darwin 通知是因为它无载荷，SB 分不清「滑条动了一下」和「刚进页面」。 */
    @try {
        CFStringRef domain = (__bridge CFStringRef)AevonPrefsDomain;
        double stamp = [[NSDate date] timeIntervalSince1970];
        CFPreferencesSetAppValue(CFSTR("AevonPreviewReq"),
                                 (__bridge CFPropertyListRef)@(stamp),
                                 domain);
        CFPreferencesAppSynchronize(domain);
    } @catch (NSException *exception) {
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self aevonHookSliders];
}

#pragma mark - V0.2.9：开关行内 ⓘ（点开就是完整说明）

/* 说明按钮与说明文本的关联键（cell → 按钮，按钮 → 文本） */
static char AevonInfoButtonKey;
static char AevonInfoTextKey;

/*
 * 用户 Aevon(95) 的原话：「设置中的开关注释并不清晰，可以简化开关名字，
 * 然后开关名字后面添加圆圈叹号，点击会出现开关的详细注释」。
 *
 * 做法：开关名字只留短词（「边缘呼出」「App 内右缘接管」…），
 * 完整说明放进 Root.plist 的 infoText 键；列表渲染时在开关左边补一个系统自带的
 * 「ⓘ」（UIButtonTypeInfoLight，圆圈里一个 i），点它弹一个 UIAlertController。
 *
 * 为什么不写在 label 里：之前十几个开关的 label 是一整段 300 字的说明，设置页看起来
 * 像一堵墙 —— 名字找不着、说明也读不完。为什么不给 PSSwitchCell 加 accessory：
 * 那个位置被 UISwitch 占着，硬塞会把开关挤没。
 *
 * 安全约束：所有 runtime 取值都走 @try；拿不到 specifier / infoText 就什么都不加
 * （退回「只有短名字」的原生样子，绝不空白、绝不崩）。
 */
- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    /* 注意：**不调用 super**。
     * PSListController 继承的是 UIViewController（不是 UITableViewController），
     * 它自身并没有实现这个方法 —— 调 super 既过不了编译（本工程 -Werror），
     * 运行时也会 unrecognized selector。单元的显示内容由框架在
     * cellForRowAtIndexPath / refreshCellContentsWithSpecifier: 里配好，
     * 这里只负责在它上面补一个 ⓘ 按钮。 */
    (void)indexPath;
    @try {
        id spec = nil;
        SEL specSelector = @selector(specifier);
        if ([cell respondsToSelector:specSelector]) {
            typedef id (*SpecFn)(id, SEL);
            SpecFn fn = (SpecFn)[cell methodForSelector:specSelector];
            if (fn != NULL) { spec = fn(cell, specSelector); }
        }
        NSString *info = AevonGetProperty(spec, @"infoText");
        if (![info isKindOfClass:[NSString class]] || info.length == 0) { return; }

        UIButton *button = objc_getAssociatedObject(cell, &AevonInfoButtonKey);
        if (button == nil) {
            /* 圆圈里一个 i（UIButtonTypeInfoLight）—— 就是用户说的「圆圈叹号」 */
            UIButton *created = [UIButton buttonWithType:UIButtonTypeInfoLight];
            created.tintColor = [UIColor secondaryLabelColor];
            [created addTarget:self
                        action:@selector(aevonInfoTapped:)
              forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(cell, &AevonInfoButtonKey, created, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (created.superview != cell) { [cell addSubview:created]; }
            button = created;
        }
        /* V0.2.10（AevonPrefsInfoPosV210）：从「紧贴开关左侧」改到「开关名字正后方」。
         *
         * Aevon(96) 截图 IMG_1701：ⓘ 和 UISwitch 的圆角轨道几乎贴在一起（只差 8pt），
         * 拇指想拨开关时很容易点到 ⓘ。根源是我把位置写成「从右边数第 51+26+8 个像素」，
         * 那是**猜**开关宽度，实际 UISwitch 在不同系统版本上更宽，于是两者压在一起。
         *
         * 现在改成按**文字实际宽度**定位：ⓘ 跟在名字后面 6pt，离右侧开关永远 ≥12pt。
         * 名字都是短词（4~7 个字），所以 ⓘ 落在行中间偏左 —— 既是用户原话「开关名字后面
         * 添加圆圈叹号」的字面意思，也彻底消除了误触。 */
        CGFloat side = 26.0;
        CGFloat labelRight = 16.0;
        @try {
            UILabel *text = [cell respondsToSelector:@selector(textLabel)] ? cell.textLabel : nil;
            if (text != nil && text.text.length > 0) {
                CGSize fit = [text sizeThatFits:CGSizeMake(CGFLOAT_MAX, text.bounds.size.height)];
                CGFloat shown = MIN(fit.width, text.bounds.size.width);
                if (shown > 1.0) { labelRight = CGRectGetMinX(text.frame) + shown; }
            }
        } @catch (NSException *exception) {
            labelRight = 16.0;
        }
        /* 右侧留够：开关约 51pt + 右边距 10pt + 与 ⓘ 之间的 12pt 空隙 */
        CGFloat ceiling = cell.bounds.size.width - 51.0 - 10.0 - 12.0 - side;
        CGFloat x = MIN(labelRight + 6.0, MAX(16.0, ceiling));
        CGRect frame = button.frame;
        frame.size = CGSizeMake(side, side);
        frame.origin.x = x;
        frame.origin.y = (cell.bounds.size.height - side) * 0.5;
        button.frame = frame;
        button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        /* cell 会被复用，文案每次刷新 */
        objc_setAssociatedObject(button, &AevonInfoTextKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *exception) {
        /* 说明按钮加不上就不加，设置页照常可用 */
    }
}

- (void)aevonInfoTapped:(UIButton *)sender {
    if (sender == nil) { return; }
    NSString *info = objc_getAssociatedObject(sender, &AevonInfoTextKey);
    if (![info isKindOfClass:[NSString class]] || info.length == 0) { return; }

    /* 标题取开关自己的名字（往上找承载它的 cell） */
    NSString *title = @"开关说明";
    @try {
        UIView *node = sender.superview;
        while (node != nil && ![node isKindOfClass:[UITableViewCell class]]) {
            node = node.superview;
        }
        if (node != nil && [node respondsToSelector:@selector(specifier)]) {
            SEL specSelector = @selector(specifier);
            typedef id (*SpecFn)(id, SEL);
            SpecFn fn = (SpecFn)[node methodForSelector:specSelector];
            if (fn != NULL) {
                id spec = fn(node, specSelector);
                id label = AevonGetProperty(spec, @"label");
                if ([label isKindOfClass:[NSString class]] && [label length] > 0) {
                    title = (NSString *)label;
                }
            }
        }
    } @catch (NSException *exception) {
    }
    /* 点击 ⓘ 不该顺带切换开关，也不该让这一行变成选中态 */
    @try {
        UIView *node = sender.superview;
        UITableViewCell *hostCell = nil;
        if ([node isKindOfClass:[UITableViewCell class]]) { hostCell = (UITableViewCell *)node; }
        while (node != nil && ![node isKindOfClass:[UITableView class]]) { node = node.superview; }
        if ([node isKindOfClass:[UITableView class]] && hostCell != nil) {
            NSIndexPath *path = [(UITableView *)node indexPathForCell:hostCell];
            if (path != nil) { [(UITableView *)node deselectRowAtIndexPath:path animated:NO]; }
        }
    } @catch (NSException *exception) {
    }
    [self aevonPresentInfo:info title:title];
}

- (void)aevonPresentInfo:(NSString *)info title:(NSString *)title {
    if (self.presentedViewController != nil) { return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:info
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    @try {
        [self presentViewController:alert animated:YES completion:nil];
        NSLog(@"[Aevon] 开关说明已弹出：%@（AevonPrefsInfoV209）", title);
    } @catch (NSException *exception) {
    }
}

/* 递归找所有 UISlider（PSSliderCell 内部的控件），每个只挂一次 valueChanged */
- (void)aevonHookSliders {
    [self aevonWalkSliders:self.view depth:0];
}

- (void)aevonWalkSliders:(UIView *)view depth:(NSInteger)depth {
    if (view == nil || depth > 16) return;
    if ([view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)view;
        if (objc_getAssociatedObject(slider, &AevonSliderTagKey) == nil) {
            objc_setAssociatedObject(slider, &AevonSliderTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            /* 连续回报：PSSliderCell 在部分系统上只在松手时发一次 valueChanged，
             * 那样触发条就只能在抬手后跳一下 —— 用户要的是「拖着滑条，条跟着走」。 */
            slider.continuous = YES;
            [slider addTarget:self
                       action:@selector(aevonSliderValueChanged:)
             forControlEvents:UIControlEventValueChanged];
            /* 手指刚按下先把滑块校正到真实值（防止显示与实际不一致时越拖越偏） */
            [slider addTarget:self
                       action:@selector(aevonSliderTouchDown:)
             forControlEvents:UIControlEventTouchDown];
            [self aevonSyncSlider:slider];
        }
        return;
    }
    for (UIView *sub in view.subviews) {
        [self aevonWalkSliders:sub depth:depth + 1];
    }
}

#pragma mark - V0.0.28：滑条 ↔ 触发条 双向同步

/* 往上找承载它的 UITableViewCell，再取 specifier 的 key */
- (NSString *)aevonKeyForSlider:(UISlider *)slider specifier:(id *)outSpecifier {
    UIView *node = slider;
    while (node != nil && ![node isKindOfClass:[UITableViewCell class]]) {
        node = node.superview;
    }
    id spec = nil;
    if (node != nil && [node respondsToSelector:@selector(specifier)]) {
        spec = [node performSelector:@selector(specifier)];
    }
    if (outSpecifier != NULL) *outSpecifier = spec;
    id key = AevonGetProperty(spec, @"key");
    return [key isKindOfClass:[NSString class]] ? (NSString *)key : nil;
}

/* 把存储值压回滑块 + 让 PSSliderCell 右侧的数值标签一起更新 */
- (void)aevonSyncSlider:(UISlider *)slider {
    id spec = nil;
    NSString *key = [self aevonKeyForSlider:slider specifier:&spec];
    if (key.length == 0) return;
    NSNumber *stored = AevonPrefsNumber(key);
    double value = stored.doubleValue;
    if (stored == nil) {
        id def = AevonGetProperty(spec, @"default");
        if ([def respondsToSelector:@selector(doubleValue)]) {
            value = [def doubleValue];
        } else {
            return;
        }
    }
    if (value < slider.minimumValue) value = slider.minimumValue;
    if (value > slider.maximumValue) value = slider.maximumValue;
    [slider setValue:(float)value animated:NO];

    /* 让框架自己的数值标签显示同一个数（"value"/"default" 两个键不同版本分别读） */
    AevonSetProperty(spec, @(value), @"value");
    AevonSetProperty(spec, @(value), @"default");
    UITableViewCell *cell = (UITableViewCell *)slider.superview;
    while (cell != nil && ![cell isKindOfClass:[UITableViewCell class]]) {
        cell = (UITableViewCell *)cell.superview;
    }
    if (cell != nil && [cell respondsToSelector:@selector(refreshCellContentsWithSpecifier:)]) {
        @try {
            [cell performSelector:@selector(refreshCellContentsWithSpecifier:) withObject:spec];
        } @catch (NSException *exception) {
        }
    }
    /* refresh 可能又把滑块设回旧值，最后再压一次确保位置正确 */
    [slider setValue:(float)value animated:NO];
    slider.continuous = YES;
}

- (void)aevonSyncAllSliders {
    [self aevonWalkSync:self.view depth:0];
}

- (void)aevonWalkSync:(UIView *)view depth:(NSInteger)depth {
    if (view == nil || depth > 16) return;
    if ([view isKindOfClass:[UISlider class]]) {
        [self aevonSyncSlider:(UISlider *)view];
        return;
    }
    for (UIView *sub in view.subviews) {
        [self aevonWalkSync:sub depth:depth + 1];
    }
}

- (void)aevonSliderTouchDown:(UISlider *)slider {
    [self aevonSyncSlider:slider];
}

/*
 * 拖动过程中每一帧：写回偏好 + 广播 com.aevon.prefschanged。
 * SpringBoard 收到后 synchronize + 比对指纹 + 重排触发条 —— 视觉上就是"跟手"。
 * PSSliderCell 自己只在某些系统版本上「松手才提交」，所以这里必须自己写。
 */
- (void)aevonSliderValueChanged:(UISlider *)slider {
    id spec = nil;
    NSString *key = [self aevonKeyForSlider:slider specifier:&spec];
    if (key.length > 0) {
        CFStringRef domain = (__bridge CFStringRef)AevonPrefsDomain;
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)@(slider.value),
                                 domain);
        CFPreferencesAppSynchronize(domain);
        /* 数值标签跟着手指走（不然只有滑块在动、数字不动） */
        AevonSetProperty(spec, @(slider.value), @"default");
    }
    /* 拖动时每帧都会走到这里：写偏好不节流，但跨进程通知限到 ~30ms 一次，
     * 免得 SpringBoard 被通知洪水拖慢（视觉上仍然跟手）。 */
    static CFTimeInterval lastPost = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (lastPost == 0 || now - lastPost >= 0.03) {
        lastPost = now;
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.aevon.prefschanged"),
                                             NULL, NULL, true);
    }
}

/* 一键恢复触发区默认值：位置 75% / 宽 48pt / 高 320pt */
- (void)aevonResetTriggerZone {
    NSDictionary *defaults = @{ @"RingTriggerY": @75,
                                @"RingTriggerWidth": @48,
                                @"RingTriggerHeight": @320 };
    CFStringRef domain = (__bridge CFStringRef)AevonPrefsDomain;
    [defaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) {
        (void)stop;
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain);
    }];
    CFPreferencesAppSynchronize(domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.prefschanged"),
                                         NULL, NULL, true);
    @try {
        [self reloadSpecifiers];
    } @catch (NSException *exception) {
    }
    [self aevonSyncAllSliders];
}

#pragma mark - V0.0.27：圆盘 App 编辑器入口

- (void)aevonOpenRingEditor {
    Class cls = NSClassFromString(@"AevonRingEditorController");
    if (cls == Nil) {
        return;
    }
    UIViewController *editor = [[cls alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

/* V0.0.30（AevonDetailPageV30）：一级页只放开关，滑杆 / 恢复默认 / 圆盘 App 编辑
 * 全部搬进二级页 —— 用户 Aevon(23) 要求「一级菜单只显示开关选项」。 */
- (void)aevonOpenDetail {
    UIViewController *detail = nil;
    Class cls = NSClassFromString(@"AevonDetailListController");
    if (cls != Nil) {
        detail = [[cls alloc] init];
        if ([detail respondsToSelector:@selector(setTitle:)]) {
            [detail performSelector:@selector(setTitle:) withObject:@"细节调整"];
        }
    }
    if (detail == nil) return;
    UINavigationController *nav = self.navigationController;
    if (nav != nil) {
        [nav pushViewController:detail animated:YES];
    } else {
        /* 兜底：不在导航栈里就模态弹出（正常路径永远走 push） */
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:detail];
        wrap.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:wrap animated:YES completion:nil];
    }
}

@end

#pragma mark - V0.0.30：二级「细节调整」页

@interface AevonDetailListController : AevonRootListController
@end

@implementation AevonDetailListController

- (NSArray *)specifiers {
    NSArray *cached = AevonCachedSpecifiers(self);
    if (cached != nil) return cached;

    NSArray *list = nil;
    @try {
        list = [self loadSpecifiersFromPlistName:@"Detail" target:self];
    } @catch (NSException *exception) {
        list = nil;
    }
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) list = nil;

    if (list == nil) {
        NSBundle *bundle = nil;
        @try { bundle = [NSBundle bundleForClass:[self class]]; } @catch (NSException *e) { bundle = nil; }
        if (bundle == nil) bundle = [NSBundle mainBundle];
        list = AevonBuildFromPlist(self, bundle, @"Detail");
    }

    if (list == nil) list = AevonBuildFallbackDetail(self);
    if (list.count > 0) AevonStoreSpecifiers(self, list);
    return list ?: @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.title.length == 0) self.title = @"细节调整";
    AevonLogPrefsSync();
    /* 标记：CI 校验二级页逻辑确实编入（AevonDetailPageV30） */
    static char once; (void)once;
    NSString *marker = @"AevonDetailPageV30";
    if (marker.length == 0) { return; }
}

@end
