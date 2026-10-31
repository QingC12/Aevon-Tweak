/* AevonSceneCensus.h —— V0.3.41（AevonSceneCensusV341）
 *
 * C 路线第一步：**SpringBoard 场景承载通路的只读普查**。
 *
 * 背景（为什么 C 的第一步必须是取证而不是改代码）
 * -------------------------------------------------
 * 0.3.34~0.3.40 七版都在「主场景改画布（S2）」这个承载模型里打补丁：
 * 写前台、挂断言、续持断言、零写铁律、重建 presenter。Aevon(111) 日志把这条路
 * 的天花板钉死了：
 *   29.522 我们自己写 fg=YES（此刻 cs=2，画面明明在）
 *   29.701 断言续持 3 秒开始
 *   30.702 **cs=0**（断言还在，表面照样被收走）
 *   30.707 补写只到 cs=1（一次 updateSettings 换不回远程层）
 * 结论：S2 模型里「App 主场景」天生属于全屏 App，用户回桌面它就该被收走 ——
 * 这是模型的必然结果，不是参数没调对。要真正零中断，只能换承载模型（C 路线）。
 *
 * C 路线的落点是「浮窗自己拥有一个 App 场景」：场景是我们建的，
 * 系统就不会因为「用户回桌面」把它当成 App 的后台场景收走。
 * 本工程 0.2.28~0.2.80 试过这条（AevonSelfSceneV228 / AevonSelfSceneFGV232 /
 * AevonAppSceneTakeoverV234 / AevonSelfSceneOffV281），结论是「场景建得出来，
 * App 端永远不接」—— 连接取证恒为 `client=FBWorkspace clientPort=nil`。
 *
 * 而 Mango（五家里唯一「造真 UIApplicationScene」的）用的**也是**
 * `createSceneWithDefinition:initialParameters:`（MangoHello 串表实锤），
 * 差别只在它同时用 `_SBDeviceApplicationSceneHandle` 把场景包了一层。
 * 也就是说：缺的很可能不是「创建」，而是「场景 → App 场景句柄 → App 进程」这一跳。
 *
 * 但那一跳的**真实方法名我们不知道**，而「在 SpringBoard 里猜选择子并调用」
 * = 一次注销（0.2.72 SIGTRAP / 归档(13)(14) 都是这么来的）。
 * 所以本版只做一件事：把 SB 侧候选类的**完整方法表**、以及**掉画时刻的现场**
 * 只读 dump 回来，下一版照实证名字落地。
 *
 * 纪律
 * ----
 *  · 全程 `@try/@catch`：Swift 抓不到 NSException，未知选择子直接 SIGABRT。
 *  · **零写**：本文件不出现任何 updateSettings / setForeground / setSuspended /
 *    destroyScene / createScene 调用（CI 断言锁死）。只读 KVC 与 respondsToSelector。
 *  · 每个进程只跑一次（`gRan`）；总闸 `AevonSceneCensusOff341` 写 true 即整段不跑。
 *  · 标量一律走 KVC（`valueForKey:` 装箱），绝不 `object_getIvar` 读非对象类型
 *    （0.3.36 教训：对非对象 SIGSEGV，跑在 SB 里 = 一次注销，@try 都抓不住）。
 */
#ifndef AEVON_SCENE_CENSUS_H
#define AEVON_SCENE_CENSUS_H

#ifdef __cplusplus
extern "C" {
#endif

/// 一次性普查：候选类的完整方法表 + 一个真实场景的现场快照。
/// 传入**真实** FBScene 实例（void *，不接管所有权）。
/// 返回 1 = 本次跑了；0 = 跳过（总闸关闭 / 已跑过 / scene 为空）。
int AevonSceneCensusRun(void *scene);

/// 单次现场采样（回桌面掉画前后各打几拍，用来定位「画面是在哪一步没的」）。
/// tag 只进日志，不参与任何判断。
void AevonSceneCensusSample(void *scene, const char *tag);

#ifdef __cplusplus
}
#endif

#endif /* AEVON_SCENE_CENSUS_H */
