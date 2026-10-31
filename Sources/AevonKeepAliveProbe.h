/* AevonKeepAliveProbe.h —— V0.3.26（AevonKeepAliveProbeV326）
 *
 * 场景保活探针的 C 接口（实现在 AevonKeepAliveProbe.m，全部 @try/@catch + fail-open）。
 * Swift 侧用 @_silgen_name 直调。
 *
 *   AevonKeepAliveProbeBegin(scene)  回桌面那一刻调用；返回 1 = 本轮探针已执行
 *   AevonKeepAliveProbeEnd()         让位结束 / 撤帧时调用；释放断言
 *   AevonKeepAliveProbeActive()      1 = 探针正在持有断言
 */
#ifndef AEVON_KEEP_ALIVE_PROBE_H
#define AEVON_KEEP_ALIVE_PROBE_H

int AevonKeepAliveProbeBegin(void *scene);
void AevonKeepAliveProbeEnd(void);
int AevonKeepAliveProbeActive(void);

#endif /* AEVON_KEEP_ALIVE_PROBE_H */
