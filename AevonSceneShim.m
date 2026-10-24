/* CI 标记（V0.0.75）：安全方法调用垫片必须编进主 dylib（
 * Aevon(67) 自动注销的根治点：BOOL 返回值被 perform 当成对象指针）。 */

#import "AevonSceneShim.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

/* 历史版本标记（只作 CI / 日志对账，不含逻辑） */
__attribute__((used)) static const char AevonSceneSafeCallV75Marker[] = "AevonSceneSafeCallV75";
__attribute__((used)) static const char AevonSceneSafeObjV76Marker[] = "AevonSceneSafeObjV76";
__attribute__((used)) static const char AevonSceneProxyObjCV76Marker[] = "AevonP1ProxyObjCV76";
__attribute__((used)) static const char AevonP1ExcV86Marker[] = "AevonP1ExcV86";
__attribute__((used)) static const char AevonP1Init2V86Marker[] = "AevonP1Init2V86";
__attribute__((used)) static const char AevonSceneScanObjCV77Marker[] = "AevonSceneScanObjCV77";
__attribute__((used)) static const char AevonGuardAliveV77Marker[] = "AevonGuardAliveV77";
__attribute__((used)) static const char AevonProviderGraphV78Marker[] = "AevonProviderGraphV78";
__attribute__((used)) static const char AevonAliveFileV78Marker[] = "AevonAliveFileV78";

/* V0.0.88：真小胖屏（自建场景 / displayConfiguration / 真 resize）与
 * P0 / P1 探针已按用户要求整体移除 —— 归档(8) 终审（P1 第 4 步
 * SBDeviceApplicationSceneEntity 的 5 个候选 init 全部返回 nil）判死这条路。
 * 相关函数与垫片一并删除；本文件只保留 Guard 存活登记
 * （SpringBoard 侧「浮窗内容触摸降级」判据依赖它，见 AevonSceneHost.swift）。 */

/* ── Guard 存活登记（V0.0.77 notify / V0.0.78 文件，双路）── */

int AevonGuardAliveFileState(NSString *bundleID) {
    if (bundleID.length == 0) { return 0; }
    @try {
        NSString *path = [@"/var/mobile/Aevon.alive." stringByAppendingString:bundleID];
        NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (s.length == 0) { return 0; }
        int pid = s.intValue;
        if (pid <= 0) { return 0; }
        /* 进程还活着才算数（App 被杀掉后旧文件不该让人误判） */
        if (kill((pid_t)pid, 0) != 0 && errno != EPERM) { return 0; }
        return pid;
    } @catch (NSException *e) { return 0; }
}

int AevonGuardAliveState(NSString *bundleID) {
    if (bundleID.length == 0) { return 0; }
    /* V0.0.78（AevonAliveFileV78）：**文件优先**。
     * Aevon(70) 实测：Guard 明明在 6 个 App 进程里都在打日志（吞摸取证带着对应 bundle），
     * notify state 读回来全是 0 —— 6 个浮窗全被误判成「无 Guard」而关掉了内容触摸。
     * 文件 + kill(pid,0) 这条路 Aevon.log 已经证明可用（App 进程能写 /var/mobile），
     * 读到就直接返回；读不到再退回 notify state。 */
    int filePid = AevonGuardAliveFileState(bundleID);
    if (filePid > 0) { return filePid; }
    @try {
        NSString *name = [@"com.aevon.alive." stringByAppendingString:bundleID];
        int token = -1;
        if (notify_register_check(name.UTF8String, &token) != 0 || token < 0) {
            return 0;
        }
        uint64_t st = 0;
        if (notify_get_state(token, &st) != 0) {
            notify_cancel(token);
            return 0;
        }
        notify_cancel(token);
        return (int)(st & 0x7FFFFFFF);
    } @catch (NSException *e) {
        return 0;
    }
}
