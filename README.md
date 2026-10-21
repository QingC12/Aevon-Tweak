# SplitKit — 从零实现的 Swift iOS 越狱分屏插件

参考 Stheno（奥利奥分屏）逆向数据，从 0 复刻的越狱分屏插件。

- 语言：**全程 Swift**（仅保留两个极小的 ObjC 文件：dyld 构造函数桥 + 异常安全的 RBSAssertion 保活垫片）
- Hook 方式：**Objective-C 运行时方法交换**（不依赖 Orion / Substrate API / Logos）
- 打包：theos + `THEOS_PACKAGE_SCHEME=rootless`（安装到 `/var/jb`，兼容 relaxin' + roothide）
- 架构：fat 二进制 **arm64 + arm64e**（覆盖 A12–A17，含 iPhone 15 Pro Max）
- 构建：GitHub Actions macOS runner 云端构建，无需本地 Mac

## 安全设计（最高优先级）

1. **V0.0.1 为安全骨架**：加载后只写日志、读偏好，不 hook 任何系统类，不存在卡开机风险。
2. **开机崩溃保护**：加载时写入 `loading` 状态，SpringBoard 稳定 20 秒后写 `healthy`；
   若下次加载发现上次仍是 `loading`（说明上次加载后崩溃），立即自动禁用插件，
   阻断「崩溃 → 重启 → 再崩溃」的死循环。禁用后可在 设置 → SplitKit 重新开启。
3. **首个带 hook 的版本（V0.0.2）默认关闭**：需要在 设置 → SplitKit 手动打开开关并注销后生效。
4. **所有私有 API 访问均有运行时守卫**：类不存在 / 方法不存在 / 取值失败时只记录日志并放弃，
   绝不解包失败、绝不让异常逃逸到 dyld 构造函数。
5. **hook 只影响被窗口化的 App**：前台保持、拦截停用等逻辑仅在用户主动开窗后才作用于对应场景，
   未开窗时系统行为与原生生完全一致。
6. **父类方法复制再交换**：hook 继承自父类的方法时，先把实现复制到目标类再交换，
   绝不影响该父类的其他子类。

## 目录结构

```
SplitKit/
├── Makefile                    # theos 构建（ARCHS=arm64 arm64e, rootless）
├── control                     # deb 控制信息
├── SplitKit.plist              # MobileSubstrate 注入过滤（仅 SpringBoard）
├── ctor.m                      # dyld 构造函数桥（转发到 Swift）
├── AssertionShim.h/.m          # RBSAssertion 保活垫片（ObjC @try/@catch）
├── SplitKit-Bridging-Header.h  # Swift ↔ ObjC 桥接头
├── Sources/                    # 全部 Swift 源码
│   ├── SplitKit.swift          #   入口 / hook 安装
│   ├── SKLog.swift             #   日志
│   ├── SKPrefs.swift           #   偏好读写
│   ├── SKCrashGuard.swift      #   开机崩溃保护
│   ├── SKRuntime.swift         #   ObjC 运行时工具（ivar / perform / IMP）
│   ├── SKSwizzle.swift         #   安全方法交换（无 Orion）
│   ├── SKForegroundManager.swift # 前台保活登记
│   ├── SKAppInfo.swift         #   SBApplication 查询
│   ├── SKAppLayout.swift       #   多任务卡片布局解析
│   ├── SKSceneHelper.swift     #   FBScene 查找 / 场景承载 / 前台控制
│   ├── SKHostWindow.swift      #   穿透宿主窗口
│   ├── SKWindowView.swift      #   浮窗外壳（拖动/缩放/关闭）
│   ├── SKWindowManager.swift   #   开窗 / 关窗管理
│   ├── SKGestureHandler.swift  #   长按手势
│   └── Hooks.swift             #   全部 hook 类
├── splitkitprefs/              # 设置面板子工程（静态 plist，无自定义代码）
└── .github/workflows/build.yml # CI：构建 + 架构校验 + Release
```

## 构建

推送即构建（见 `.github/workflows/build.yml`）：

1. macOS runner 安装 theos（含子模块）与 theos/sdks；
2. `make package FINALPACKAGE=1`（rootless 布局，fat arm64+arm64e）；
3. CI 自动解包校验产物必须包含 **arm64e** slice；
4. tag（`v*`）推送时自动创建 GitHub Release 并附带 deb。

本地（有 Mac 时）：

```bash
export THEOS=~/theos
make clean && make package FINALPACKAGE=1
```

## 安装与使用（设备）

1. 将 `packages/com.splitkit.tweak_<版本>_iphoneos-arm64.deb` 传到设备；
2. 用 roothide 环境的包管理器（Sileo/Zebra）或 dpkg 安装；
3. 注销（Respring）SpringBoard；
4. **设置 → SplitKit → 打开「启用插件」→ 再次注销**（V0.0.2 起默认关闭）；
5. 用法：
   - 把目标 App 切到后台（留在多任务卡片），**长按该卡片**即可窗口化；
   - 或在主屏**长按 App 图标**，选择快捷菜单中的「Open in Window」；
6. 浮窗操作：拖标题栏移动、拖右下角圆点缩放、点 ✕ 关闭。

## 版本记录

| 版本 | 内容 |
|---|---|
| V0.0.1 | 安全骨架：加载链路、偏好开关、开机崩溃保护、设置面板；不 hook 任何系统类。 |
| V0.0.2 | 最小浮窗：多任务卡片 / 图标长按开窗；App 场景承载；拖动、缩放、关闭；前台保活；崩溃保护。 |
