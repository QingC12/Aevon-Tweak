/*
 * Aevon 设置页的「圆盘 App」编辑器（V0.0.27）
 * =====================================================================
 * 需求（用户 Aevon(20)）：
 *   · 在设置里能**自定义圆盘里放哪些 App**；
 *   · 在二级菜单里能**给已选 App 排序**（进入编辑模式，上下拖动排序，要简洁）。
 *
 * 为什么不用 PSListController：
 *   specifier 数组和偏好数组是两套索引，拖动重排要自己维护映射，
 *   而且 PSListController 没有现成的「编辑模式拖动」入口。
 *   这里直接用 UIViewController + UITableView，行为完全可控：
 *     · 右上「添加」→ 推入全量 App 列表，点一下即加入 / 再点移除；
 *     · 右上「编辑」→ 打开系统编辑模式：右侧出现拖动把手，可上下拖排序、左滑删除；
 *     · 每次改动立刻写回偏好域 com.Aevon 的 RingApps 并广播 com.aevon.prefschanged，
 *       SpringBoard 侧收到就清缓存，下次呼出圆盘即是新顺序。
 *
 * 存储格式与 SpringBoard 侧 `AevonRingStore` 完全一致：CFArray<CFString>，顺序 = 圆盘顺序。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

static NSString *const AevonRingDomain = @"com.Aevon";
static NSString *const AevonRingAppsKey = @"RingApps";
static NSUInteger const AevonRingMax = 36;

#pragma mark - 偏好读写

static NSArray<NSString *> *AevonRingReadList(void) {
    CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("RingApps"),
                                                      (__bridge CFStringRef)AevonRingDomain);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (raw != NULL) {
        if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
            CFArrayRef array = (CFArrayRef)raw;
            CFIndex count = CFArrayGetCount(array);
            for (CFIndex i = 0; i < count; i++) {
                CFStringRef item = (CFStringRef)CFArrayGetValueAtIndex(array, i);
                if (item != NULL && CFGetTypeID(item) == CFStringGetTypeID()) {
                    NSString *value = (__bridge NSString *)item;
                    if (value.length > 0 && ![out containsObject:value]) {
                        [out addObject:value];
                    }
                }
            }
        }
        CFRelease(raw);
    }
    return out;
}

static void AevonRingWriteList(NSArray<NSString *> *list) {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *item in list) {
        if (![item isKindOfClass:[NSString class]] || item.length == 0) continue;
        if ([clean containsObject:item]) continue;
        [clean addObject:item];
        if (clean.count >= AevonRingMax) break;
    }
    CFPreferencesSetAppValue(CFSTR("RingApps"),
                             (__bridge CFPropertyListRef)clean,
                             (__bridge CFStringRef)AevonRingDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)AevonRingDomain);
    /* 通知 SpringBoard：圆盘下次展开要读新列表（它会顺便清掉进程内缓存） */
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.prefschanged"),
                                         NULL, NULL, true);
}

#pragma mark - 已安装 App 列表（设置进程侧）

/* LSApplicationWorkspace 是私有 API，但设置进程里可用；这里只读 bundleID / 名字 / 类型。 */
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSURL *bundleURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

static NSArray<NSDictionary *> *AevonInstalledApps(void) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass == Nil) return out;
        id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        if (workspace == nil) return out;
        NSArray *apps = [workspace performSelector:@selector(allInstalledApplications)];
        if (![apps isKindOfClass:[NSArray class]]) return out;

        for (id proxy in apps) {
            @autoreleasepool {
                NSString *bundleID = nil;
                NSString *name = nil;
                NSString *type = nil;
                @try {
                    bundleID = [proxy valueForKey:@"bundleIdentifier"];
                    name = [proxy valueForKey:@"localizedName"];
                    type = [proxy valueForKey:@"applicationType"];
                } @catch (NSException *exception) {
                    continue;
                }
                if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) continue;
                if (![type isKindOfClass:[NSString class]]) continue;
                /* 只要用户 App 与桌面可见的系统 App；排除 Hidden / Internal / 扩展 */
                if (!([type isEqualToString:@"User"] || [type isEqualToString:@"System"])) continue;
                if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bundleID;
                [out addObject:@{@"id": bundleID, @"name": name}];
            }
        }
    } @catch (NSException *exception) {
        /* 拿不到就返回已收集到的部分，绝不抛给设置页 */
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return out;
}

/// 应用图标（私有 API，失败返回 nil，由调用方画首字母色块）
static UIImage *AevonIconForBundle(NSString *bundleID, CGFloat size) {
    if (bundleID.length == 0) return nil;
    /* V0.2.69（AevonPrefsIconV269，用户 Aevon(41) #3「设置中圆盘应用编辑页面中的
     * 截图和录屏显示白图标」）：截图 / 录屏是动作不是 App —— 私有 API
     * _applicationIconImageForBundleIdentifier: 对不存在的 bundleID 返回的是
     * **白色占位图**（不是 nil），所以 0.2.63 的兜底链根本走不到色块那步。
     * 动作槽在这里直接画 SF Symbol（和圆盘上的同款视觉）。 */
    if ([bundleID hasPrefix:@"aevon.action."]) {
        NSString *symbol = [bundleID isEqualToString:@"aevon.action.screenshot"]
            ? @"camera.viewfinder" : @"record.circle";
        UIImage *glyph = [UIImage systemImageNamed:symbol];
        if (size < 8) size = 32;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
        UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size)
                                                      cornerRadius:size * 0.2237];
        UIColor *tint = [bundleID isEqualToString:@"aevon.action.screenshot"]
            ? [UIColor colorWithRed:0.29 green:0.52 blue:1.00 alpha:1.0]
            : [UIColor colorWithRed:1.00 green:0.35 blue:0.31 alpha:1.0];
        [tint setFill];
        [bg fill];
        if (glyph != nil) {
            UIImage *white = [glyph imageWithTintColor:[UIColor whiteColor]
                                       renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGFloat side = size * 0.62;
            [white drawInRect:CGRectMake((size - side) / 2, (size - side) / 2, side, side)];
        }
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return out;
    }
    Class imageClass = [UIImage class];
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([imageClass respondsToSelector:selector]) {
        typedef UIImage *(*IconFn)(id, SEL, NSString *, int, CGFloat);
        IconFn fn = (IconFn)[imageClass methodForSelector:selector];
        if (fn != NULL) {
            for (int format = 1; format >= 0; format--) {
                @try {
                    UIImage *image = fn(imageClass, selector, bundleID, format, 0);
                    if (image != nil && image.size.width > 0) return image;
                } @catch (NSException *exception) {
                }
            }
        }
    }
    return nil;
}

/// 名字首字的色块图标（取不到原生图标时的兜底）
static UIImage *AevonLetterIcon(NSString *name, NSString *bundleID, CGFloat size) {
    if (size < 8) size = 32;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    NSUInteger hash = bundleID.hash;
    CGFloat hue = (CGFloat)(hash % 360) / 360.0;
    UIColor *color = [UIColor colorWithHue:hue saturation:0.55 brightness:0.78 alpha:1.0];
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size)
                                                       cornerRadius:size * 0.24];
    [color setFill];
    [path fill];
    NSString *letter = name.length > 0 ? [name substringToIndex:1] : @"?";
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:size * 0.52 weight:UIFontWeightSemibold],
                             NSForegroundColorAttributeName: [UIColor whiteColor] };
    CGSize textSize = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:CGPointMake((size - textSize.width) / 2, (size - textSize.height) / 2)
         withAttributes:attrs];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - 编辑页（已选 App + 排序）

@interface AevonRingEditorController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *nameCache;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@end

@implementation AevonRingEditorController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _items = [NSMutableArray arrayWithArray:AevonRingReadList()];
        _nameCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"圆盘 App";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 56;
    self.table.allowsSelectionDuringEditing = NO;
    self.table.editing = NO;
    if (@available(iOS 15.0, *)) {
        self.table.sectionHeaderTopPadding = 0;
    }
    [self.view addSubview:self.table];

    [self aevonUpdateBarButtons];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self aevonReloadFromPrefs];
}

- (void)aevonReloadFromPrefs {
    self.items = [NSMutableArray arrayWithArray:AevonRingReadList()];
    [self.table reloadData];
}

- (void)aevonClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)aevonToggleEditing {
    [self.table setEditing:!self.table.isEditing animated:YES];
    [self aevonUpdateBarButtons];
}

/// 非编辑态：右上 `+`（添加）与「编辑」；编辑态：右上只留「完成」，左上关闭隐藏
- (void)aevonUpdateBarButtons {
    UIBarButtonItem *edit =
        [[UIBarButtonItem alloc] initWithTitle:(self.table.isEditing ? @"完成" : @"编辑")
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(aevonToggleEditing)];

    if (self.table.isEditing) {
        self.navigationItem.rightBarButtonItems = @[edit];
        self.navigationItem.leftBarButtonItem = nil;
        return;
    }

    UIBarButtonItem *add =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(aevonOpenAdd)];
    self.navigationItem.rightBarButtonItems = @[add, edit];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(aevonClose)];
}

- (void)aevonOpenAdd {
    Class cls = NSClassFromString(@"AevonRingAddController");
    if (cls == Nil) return;
    UIViewController *add = [[cls alloc] init];
    [self.navigationController pushViewController:add animated:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (NSString *)aevonNameFor:(NSString *)bundleID {
    NSString *cached = self.nameCache[bundleID];
    if (cached.length > 0) return cached;
    /* V0.2.63（AevonQuickEditableV263）：截图 / 录屏是「动作」不是 App，
     * LSApplicationProxy 查不到，这里给它们一个正常名字。 */
    if ([bundleID isEqualToString:@"aevon.action.screenshot"]) {
        self.nameCache[bundleID] = @"截图（系统）";
        return @"截图（系统）";
    }
    if ([bundleID isEqualToString:@"aevon.action.recording"]) {
        self.nameCache[bundleID] = @"录屏（系统）";
        return @"录屏（系统）";
    }
    NSString *name = bundleID;
    @try {
        Class cls = NSClassFromString(@"LSApplicationProxy");
        if (cls != Nil) {
            id proxy = [cls performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
            NSString *localized = proxy ? [proxy valueForKey:@"localizedName"] : nil;
            if ([localized isKindOfClass:[NSString class]] && localized.length > 0) name = localized;
        }
    } @catch (NSException *exception) {
    }
    self.nameCache[bundleID] = name;
    return name;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AevonRingEditorCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    NSString *bundleID = indexPath.row < self.items.count ? self.items[indexPath.row] : @"";
    NSString *name = [self aevonNameFor:bundleID];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), name];
    cell.detailTextLabel.text = bundleID;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    UIImage *icon = AevonIconForBundle(bundleID, 32);
    if (icon == nil) icon = AevonLetterIcon(name, bundleID, 32);
    cell.imageView.image = icon;
    cell.showsReorderControl = YES;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= self.items.count) return;
    [self.items removeObjectAtIndex:indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    AevonRingWriteList(self.items);
}

- (void)tableView:(UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row >= self.items.count) return;
    NSString *moved = self.items[sourceIndexPath.row];
    [self.items removeObjectAtIndex:sourceIndexPath.row];
    NSUInteger target = destinationIndexPath.row;
    if (target > self.items.count) target = self.items.count;
    [self.items insertObject:moved atIndex:target];
    AevonRingWriteList(self.items);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"共 %lu 个（上限 %lu）。点右上「编辑」后，按住右侧把手上下拖动即可排序，左滑删除。",
            (unsigned long)self.items.count, (unsigned long)AevonRingMax];
}

@end

#pragma mark - 添加页（全量 App，点一下即加入 / 再点移除）

@interface AevonRingAddController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSMutableArray<NSString *> *selected;
@end

@implementation AevonRingAddController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"添加 App / 动作";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    /* V0.2.63（AevonQuickEditableV263）：截图 / 录屏是「动作」，不是装出来的 App。
     * 放在列表最前面，删掉之后还能从「+」加回来 —— 用户 Aevon(37) #3 要的就是这个。 */
    NSArray<NSDictionary *> *actions =
        @[@{ @"id": @"aevon.action.screenshot", @"name": @"截图（系统）" },
          @{ @"id": @"aevon.action.recording",  @"name": @"录屏（系统）" }];
    self.apps = [actions arrayByAddingObjectsFromArray:AevonInstalledApps()];
    self.selected = [NSMutableArray arrayWithArray:AevonRingReadList()];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 54;
    [self.view addSubview:self.table];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AevonRingAddCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    NSDictionary *app = indexPath.row < self.apps.count ? self.apps[indexPath.row] : nil;
    NSString *bundleID = app[@"id"] ?: @"";
    NSString *name = app[@"name"] ?: bundleID;
    cell.textLabel.text = name;
    cell.detailTextLabel.text = bundleID;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    UIImage *icon = AevonIconForBundle(bundleID, 30);
    if (icon == nil) icon = AevonLetterIcon(name, bundleID, 30);
    cell.imageView.image = icon;
    cell.accessoryType = [self.selected containsObject:bundleID] ? UITableViewCellAccessoryCheckmark
                                                                : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= self.apps.count) return;
    NSString *bundleID = self.apps[indexPath.row][@"id"];
    if (bundleID.length == 0) return;

    if ([self.selected containsObject:bundleID]) {
        [self.selected removeObject:bundleID];
    } else {
        if (self.selected.count >= AevonRingMax) {
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"已达上限"
                                                    message:[NSString stringWithFormat:@"圆盘最多放 %lu 个 App，先在列表里移除几个。", (unsigned long)AevonRingMax]
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        [self.selected addObject:bundleID];
    }
    AevonRingWriteList(self.selected);
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
