#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/* V0.0.88：真小胖屏（场景尺寸 / displayConfiguration / 真 resize）与
 * P0 / P1 探针垫片已整体移除（归档(8) 终审判死自建场景路线）。
 * 只保留 Guard 存活登记：Guard 在每个 App 进程里启动时把 pid 写进
 * `com.aevon.alive.<bundleID>`（notify state + 文件两路），
 * SpringBoard 侧创建浮窗时读一下就知道「这个 App 进程里到底有没有 Guard」；
 * 没有（pid<=0）就当场降级（关掉内容触摸）+ 写日志点名。
 * （写入端在 Guard 自己进程里，见 AevonAppGuard.m 的 AevonGuardPublishAlive。） */

/// 读回登记值：>0 = 登记过的 pid，0 = 该 bundle 的进程里没有 Guard。
int AevonGuardAliveState(NSString *bundleID);
/// 文件式存活登记读回（Aevon.alive.<bundle>，pid 必须仍存活）。
int AevonGuardAliveFileState(NSString *bundleID);
