#import <Foundation/Foundation.h>

/*
 * SplitKit 加载入口。
 * dyld 构造函数保持极小：只转发到 Swift 侧的 splitkit_initialize()，
 * Swift 内部所有逻辑都有守卫，任何失败只会记录日志，不会抛出到 dyld。
 */
extern void splitkit_initialize(void);

__attribute__((constructor)) static void splitkit_constructor(void) {
    splitkit_initialize();
}
