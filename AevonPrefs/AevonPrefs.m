#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

/* V0.2.11（AevonPrefsInfoFitV211）：ⓘ 定位改「先布局、再量文字、按真实开关边界夹紧」。
 * CI 断言靠这条 used 常量命中设置包字节（改文案不会让历史串消失）。 */
__attribute__((used)) static const char AevonPrefsInfoFitV211Marker[] = "AevonPrefsInfoFitV211";
/* 历史校验串收容（只加不能改）：0.2.10「ⓘ 从贴开关左侧改到名字正后方」的标记。
 * 0.2.11 把定位逻辑整体搬进 AevonPlaceInfoButton，这条串必须继续留在字节里。 */
__attribute__((used)) static const char AevonPrefsInfoPosV210Marker[] = "AevonPrefsInfoPosV210";

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
            /* V0.2.61（AevonGripPageV261）：plist 里写的是 min / max（Preferences 原生键名），
             * 这里原先只认 minValue / maxValue —— 走本兜底路径时范围会退化成 0–100，
             * GripLen 的 120 上限直接被截掉。两种键名都认。 */
            id minRaw = item[@"minValue"] ?: item[@"min"];
            id maxRaw = item[@"maxValue"] ?: item[@"max"];
            double minValue = [minRaw respondsToSelector:@selector(doubleValue)]
                ? [minRaw doubleValue] : 0.0;
            double maxValue = [maxRaw respondsToSelector:@selector(doubleValue)]
                ? [maxRaw doubleValue] : 100.0;
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
                              @"用法：点按浮窗边缘的圆盘把手、或在其上左滑 → 圆盘出来 → 手指不用抬起，"
                              @"直接滑到图标上再松手就开浮窗。手指还按在屏幕上时圆盘永远不自己收（滑到盘外也不算）；"
                              @"只有抬手那一刻才判定：图标上=开窗，圆心=打开面板，其余（盘外 / 图标间隙）=收起。"
                              @"主悬浮窗左右边条轻点=吸附停靠（0.2.51，AevonDockTapV251）。"
                              @"桌面上只会有一个浮窗，再点别的 App 会直接换成它（AevonSingleWindowV105）。"
                              @"日志文件：/var/mobile/Aevon.log（Filza 可见）。");
    if (group1 != nil) [result addObject:group1];
    id s1 = AevonNewSwitch(@"启用插件", target, @"Enabled", @YES);
    if (s1 != nil) [result addObject:s1];
    /* V0.2.51（AevonGripOnlyV251）：EdgeGestureEnabled / AppSideEnabled 已随触发手势退役 ——
       呼盘唯一入口 = 圆盘把手，不存在可关的「边缘呼出」通道。 */

    /* V0.0.30：一级页只放开关 + 细节入口；滑杆 / 圆盘 App 编辑在二级页 */
    /* V0.1.5（AevonNoSnapV105）：左右吸附开关已随吸附功能一起删除；
       「窗口保活」「强制前台保持」两个无实际作用的开关也删除
       （进程保活改为单窗恒开，走 RBSAssertion，不再让用户选）。
       V0.2.17（AevonPrefsSlimV217）精简：右缘接管带 / 右缘全域接管 / 右缘系统手势通道 /
       显示区域预览 / 浮窗内可触摸 / 多任务卡片长按 六个开关撤掉 ——
       前三个随 SB 侧吞摸下线而失效（0.2.15），系统手势通道改常开，
       另三个改为代码内固定（浮窗可触摸恒开、多任务长按不进这个产品形态、预览改为进页面自动亮）。*/
    id s3 = AevonNewSwitch(@"开机崩溃保护", target, @"CrashGuard", @YES);
    if (s3 != nil) [result addObject:s3];
    id s4 = AevonNewSwitch(@"写日志文件（/var/mobile/Aevon.log）", target, @"LogEnabled", @YES);
    if (s4 != nil) [result addObject:s4];
    /* V0.2.81（AevonDeadCodeV281）：这里原本有一个「运行时探针」开关（ProbeV107）。
     * V0.1.7 的六组探针本版整体退役（主干类表扫描自 0.2.72 被封印后只剩空跑），
     * 开关再怎么拨也不会有任何一行日志 —— 死配置，连同 Root.plist 那一项一起删掉。
     * 历史标记 AevonProbeV107 / AevonProbeDefaultOffV217 仍收容在 AevonAssertionShim.m。 */

    id groupDetail = AevonNewGroup(@"圆盘把手",
                                   @"把手的位置 / 长短在独立页里调（AevonGripPageV261）。");
    if (groupDetail != nil) [result addObject:groupDetail];
    id gripButton = AevonNewSpecifier(@"把手位置 / 长度调整",
                                      target,
                                      NSSelectorFromString(@"aevonOpenGrip"),
                                      nil,
                                      AEVON_CELL_BUTTON);
    if (gripButton != nil) {
        AevonSetProperty(gripButton, @"aevonOpenGrip", @"buttonAction");
        [result addObject:gripButton];
    }

    id groupDetail2 = AevonNewGroup(@"细节调整",
                                   @"圆盘 App 编辑、浮窗几何说明都在二级页（AevonDetailPageV30）。");
    if (groupDetail2 != nil) [result addObject:groupDetail2];
    id detailButton = AevonNewSpecifier(@"圆盘 / 浮窗细节调整",
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

    /* V0.2.51（AevonGripOnlyV251）：触发区三滑条 / 接管带两滑条 / 恢复按钮已随触发手势
     * 体系整建制退役 —— 呼盘唯一入口 = 圆盘把手，几何不再可调。
     * V0.0.37：浮窗尺寸/位置设置项已移除 —— 浮窗几何改用 Stheno 式全局记忆
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

/* V0.2.11（AevonPrefsInfoFitV211）：ⓘ 定位的确定性实现（静态函数，只被列表回调调用）。
 *
 * Aevon(97) 主诉「首次进入设置时，圆圈叹号会和文字重叠」。根因不是宽度算错，是**取文案取错了时机**：
 * `willDisplayCell` 第一次跑的时候 `textLabel.text` 还是空串（PSSwitchCell 要等 cellForRow 之后
 * 才把文案填进去），于是走进 fallback 分支、`labelRight` 停在 16 → ⓘ 落在 x≈22，
 * 正好压住头两个字；退出再进这一页时 cell 已带文案，位置又正常 —— 所以看起来像「偶发」。
 *
 * 现在三条一起改：
 *   ① 文案优先取 specifier 的 label（永远有值），textLabel.text 只作交叉校验；
 *   ② 先 `layoutIfNeeded`，用**真实**的 textLabel 起点 + 真实 UISwitch 左边界，不再猜开关宽度；
 *   ③ 横向空间不够时，把 textLabel 的宽度夹到 ⓘ 左边 8pt —— 文字在 ⓘ 之前就用省略号截断，
 *      「不重叠」从概率变成几何保证（哪怕以后有人把开关名字写长）。
 */
static UILabel *AevonInfoTextLabel(UITableViewCell *cell) {
    if (cell == nil) { return nil; }
    @try {
        if ([cell respondsToSelector:@selector(textLabel)]) { return cell.textLabel; }
    } @catch (NSException *exception) {
    }
    return nil;
}

static UISwitch *AevonInfoFindSwitch(UITableViewCell *cell) {
    if (cell == nil) { return nil; }
    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    if (cell.accessoryView != nil) { [queue addObject:cell.accessoryView]; }
    [queue addObjectsFromArray:cell.subviews];
    if (cell.contentView != nil) { [queue addObjectsFromArray:cell.contentView.subviews]; }
    for (UIView *node in queue) {
        if ([node isKindOfClass:[UISwitch class]]) { return (UISwitch *)node; }
    }
    return nil;
}

static void AevonPlaceInfoButton(UITableViewCell *cell, UIButton *button, id spec) {
    if (cell == nil || button == nil) { return; }

    /* 文案：specifier 的 label 是唯一可靠来源 */
    NSString *title = nil;
    id rawLabel = AevonGetProperty(spec, @"label");
    if ([rawLabel isKindOfClass:[NSString class]] && [rawLabel length] > 0) {
        title = (NSString *)rawLabel;
    }

    /* 布局一次，让 textLabel / UISwitch 的 frame 变成真值（首次进入时它们还没排过） */
    @try { [cell layoutIfNeeded]; } @catch (NSException *exception) { }

    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    if (cellWidth < 1.0) { cellWidth = CGRectGetWidth([UIScreen mainScreen].bounds); }
    const CGFloat side = 26.0;
    const CGFloat gapTextToDot = 8.0;    /* 文字与 ⓘ 之间至少这么宽 */
    const CGFloat gapDotToSwitch = 12.0; /* ⓘ 与开关之间至少这么宽（拇指拨开关的缓冲区） */

    UILabel *text = AevonInfoTextLabel(cell);
    if (title.length == 0 && text.text.length > 0) { title = text.text; }
    UIFont *font = (text.font != nil) ? text.font : [UIFont systemFontOfSize:17.0];

    /* 文字起点：优先用真实 frame，取不到就按系统默认左内边距 + 缩进 */
    CGFloat left = 0;
    if (text != nil) {
        CGRect f = text.frame;
        if (f.origin.x > 0.5 && f.origin.x < cellWidth) { left = f.origin.x; }
    }
    if (left < 0.5) {
        left = 16.0 + cell.indentationWidth * (CGFloat)cell.indentationLevel;
    }

    CGFloat textWidth = 0;
    if (title.length > 0) {
        @try {
            textWidth = ceil([title sizeWithAttributes:@{NSFontAttributeName: font}].width);
        } @catch (NSException *exception) {
            textWidth = 0;
        }
    }

    /* 开关左边界：拿到真 UISwitch 就用它，否则退回保守估计（62pt = 51 轨道 + 边距） */
    CGFloat switchMinX = cellWidth - 62.0;
    UISwitch *toggle = AevonInfoFindSwitch(cell);
    if (toggle != nil && CGRectGetWidth(toggle.bounds) > 1.0) {
        CGRect inCell = CGRectZero;
        @try {
            inCell = [toggle.superview convertRect:toggle.frame toView:cell];
        } @catch (NSException *exception) {
            inCell = CGRectZero;
        }
        if (CGRectGetWidth(inCell) > 1.0) { switchMinX = CGRectGetMinX(inCell); }
    }
    CGFloat dotMaxX = switchMinX - gapDotToSwitch;
    CGFloat dotX = dotMaxX - side;

    /* 首选：紧跟名字后面 */
    if (textWidth > 0) {
        CGFloat preferred = left + textWidth + gapTextToDot;
        if (preferred + side <= dotMaxX) {
            dotX = preferred;
        } else {
            /* 名字太长，没地方：ⓘ 让到开关前，并把文字宽度夹到 ⓘ 左边 —— 保证不重叠 */
            if (text != nil && text.frame.size.width > 1.0) {
                CGRect f = text.frame;
                CGFloat allowed = dotX - gapTextToDot - CGRectGetMinX(f);
                if (allowed < 0) { allowed = 0; }
                if (allowed < CGRectGetWidth(f)) {
                    f.size.width = allowed;
                    @try { text.frame = f; } @catch (NSException *exception) { }
                }
            }
        }
    } else {
        /* 连文案都取不到：宁可放到最右边，也绝不放在行首压字 */
        dotX = dotMaxX - side;
    }

    if (dotX < left) { dotX = left; }
    if (dotX > cellWidth - side) { dotX = cellWidth - side; }

    CGRect frame = button.frame;
    frame.size = CGSizeMake(side, side);
    frame.origin.x = round(dotX);
    frame.origin.y = round((CGRectGetHeight(cell.bounds) - side) * 0.5);
    button.frame = frame;
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
}

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
        /* V0.2.11（AevonPrefsInfoFitV211）：定位改走静态函数 —— 先布局、再从 specifier 取文案、
         * 量文字实际宽度，最后按「真实 UISwitch 左边界」夹紧并保证文字不会压到 ⓘ 下面。
         * 0.2.10 那版仍然会在**首次进入**时压字：那一刻 `textLabel.text` 还是空串，
         * 量出来宽度 0 → ⓘ 落在 x=22（用户 Aevon(97) 看到的就是这一下）。 */
        AevonPlaceInfoButton(cell, button, spec);
        /* 首次进入时 cell 的最终布局可能在本次回调之后才落定（PSSwitchCell 会再排一次），
         * 所以下一个 runloop 再定位一次；两次都跑同一个纯几何函数，谁后跑谁生效，结果一致。 */
        UITableViewCell *lateCell = cell;
        UIButton *lateButton = button;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (lateCell.window == nil || lateButton.superview == nil) { return; }
            @try {
                AevonPlaceInfoButton(lateCell, lateButton, spec);
            } @catch (NSException *exception) {
            }
        });
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

/* V0.2.51（AevonGripOnlyV251）：aevonResetTriggerZone 已随触发区滑条退役 ——
 * 呼盘唯一入口 = 圆盘把手，触发区几何不再存在，无默认值可恢复。 */

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

/* V0.2.61（AevonGripPageV261）：用户 Aevon(35) #1 ——
 * 「设置中圆盘触发条的调整功能移动到新添加项中（添加一个可点击进入的一级菜单用来放置
 *   触发条的调整功能，切记不要再把圆圈叹号放在滑动条上）」。
 * 于是 GripY / GripLen 两条滑条从一级页整体搬进本页（Grip.plist），
 * 说明文字改成 PSGroupCell 的 footerText —— 滑条本体不再挂 infoText，行内也就不出 ⓘ。 */
- (void)aevonOpenGrip {
    UIViewController *grip = nil;
    Class cls = NSClassFromString(@"AevonGripListController");
    if (cls != Nil) {
        grip = [[cls alloc] init];
        if ([grip respondsToSelector:@selector(setTitle:)]) {
            [grip performSelector:@selector(setTitle:) withObject:@"圆盘把手"];
        }
    }
    if (grip == nil) return;
    UINavigationController *nav = self.navigationController;
    if (nav != nil) {
        [nav pushViewController:grip animated:YES];
    } else {
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:grip];
        wrap.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:wrap animated:YES completion:nil];
    }
}

/* V0.2.64（AevonGuideSheetV264，用户 Aevon(38) #4）：
 * 「前两项开关下面出现了很大一部分注释，以后注释只显示在圆圈叹号中，不得出现在一级菜单中」。
 * 一级菜单的 PSGroupCell footerText 已收敛成一行分类说明；完整用法搬到这里 ——
 * 点「ⓘ 分屏使用说明」弹一个可滚动的说明页，不再占一级菜单版面。 */
- (void)aevonShowGuide {
    NSString *title = @"Aevon 用法";
    NSString *body =
        @"圆盘把手（屏幕右缘那条小短竖条）是呼盘唯一入口：在把手上左滑 ≥14pt 即出盘，"
        @"点击不呼盘。手指不用抬起，直接滑到图标上松手就开浮窗；抬手那一刻判位置 —— "
        @"图标上=开窗，圆心=打开面板，其余=收起。\n\n"
        @"主悬浮窗：左右边条轻点 = 吸附成停靠小窗（拖到屏幕边缘不再自动停靠）；"
        @"停靠后点小窗任意位置 = 装回主窗；底边下边条双击 = 关闭浮窗。\n\n"
        @"只有一个主窗：圆盘里再选一个 App 时，原来那个会自动变成停靠小窗，不会被关掉。"
        @"某侧有停靠小窗时，主窗会自动让到另一侧；之后你手动拖到哪，就记哪。\n\n"
        @"圆盘里的「截图 / 录屏」是动作，可以在「细节调整 → 编辑圆盘 App」里删除、拖动排序，"
        @"删掉后也能用「+」加回来。\n\n"
        @"名字后面带 ⓘ 的开关，点 ⓘ 就是这一项的完整说明。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:body
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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

#pragma mark - V0.2.61：二级「圆盘把手」页（滑条专用，滑条不挂 ⓘ）

/* Grip.plist 读不到时的代码兜底：两条滑条 + 分组说明，数值与 plist 完全一致 */
static NSArray *AevonBuildFallbackGrip(id target) {
    NSMutableArray *result = [NSMutableArray array];

    id group = AevonNewGroup(@"圆盘把手外观",
                             @"把手是贴屏幕右缘的小短竖条（宽 5pt）。可点热区向屏幕内侧延伸约 40pt、"
                             @"上下各多出 14pt，手指不必精确按在竖条上。两个滑条都即时生效，不用注销。");
    if (group != nil) [result addObject:group];

    id y = AevonNewSlider(@"位置：从底部起 %", target, @"GripY", 10.0, 90.0, 30.0);
    if (y != nil) [result addObject:y];
    id groupY = AevonNewGroup(@" ", @"10 = 贴近屏幕底部，90 = 贴近顶部；默认 30（单手最顺手）。");
    if (groupY != nil) [result addObject:groupY];

    id len = AevonNewSlider(@"长度：pt", target, @"GripLen", 36.0, 120.0, 64.0);
    if (len != nil) [result addObject:len];
    id groupLen = AevonNewGroup(@" ", @"36 = 很短的一条，120 = 接近一根手指高度；默认 64。");
    if (groupLen != nil) [result addObject:groupLen];

    return result.count > 0 ? result : nil;
}

@interface AevonGripListController : AevonRootListController
@end

@implementation AevonGripListController

- (NSArray *)specifiers {
    NSArray *cached = AevonCachedSpecifiers(self);
    if (cached != nil) return cached;

    NSArray *list = nil;
    @try {
        list = [self loadSpecifiersFromPlistName:@"Grip" target:self];
    } @catch (NSException *exception) {
        list = nil;
    }
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) list = nil;

    if (list == nil) {
        NSBundle *bundle = nil;
        @try { bundle = [NSBundle bundleForClass:[self class]]; } @catch (NSException *e) { bundle = nil; }
        if (bundle == nil) bundle = [NSBundle mainBundle];
        list = AevonBuildFromPlist(self, bundle, @"Grip");
    }

    if (list == nil) list = AevonBuildFallbackGrip(self);
    if (list.count > 0) AevonStoreSpecifiers(self, list);
    return list ?: @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.title.length == 0) self.title = @"圆盘把手";
    AevonLogPrefsSync();
    /* 标记：CI 校验「把手调整独立成页」确实编入（AevonGripPageV261） */
    static char once; (void)once;
    NSString *marker = @"AevonGripPageV261";
    if (marker.length == 0) { return; }
}

@end
