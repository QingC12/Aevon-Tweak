/* AevonSnapProbe.h —— V0.3.36（AevonSnapProbeV336）
 *
 * K2-A 第一步：系统快照接口只读探针。
 *
 * 只读、只打日志、绝不改任何行为；每个进程最多跑一次。
 * 目的：把 FBScene / SBDeviceApplicationSceneHandle / SBAppSwitcherSnapshotImageCache
 * 上所有含 snapshot 的方法名与 typeEncoding 实证回来，供 0.3.37 落地时照名字调用 ——
 * 本工程铁律「真 API 名靠 census 不靠 strings/猜测」。
 */
#ifndef AEVON_SNAP_PROBE_H
#define AEVON_SNAP_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 传入一个**真实的** FBScene 实例（void *，不接管所有权）。
/// 返回 1 = 本次跑了；0 = 跳过（总闸关闭 / 已跑过 / scene 为空）。
int AevonSnapProbeRun(void *scene);

#ifdef __cplusplus
}
#endif

#endif /* AEVON_SNAP_PROBE_H */
