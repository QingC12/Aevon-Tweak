# 打包约定（勿随意更改）
#   ARCHS                 = arm64e                 设备 A17，只产 arm64e 切片
#   THEOS_PACKAGE_SCHEME  = roothide               roothide 布局，deb 架构 iphoneos-arm64e
#   Theos 来源            = roothide/theos         上游 theos 不支持 roothide scheme
#   签名                  = Procursus ldid -S      占位签名（.unsigned）在 roothide 上会崩 SpringBoard
ARCHS = arm64e
TARGET := iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Aevon AevonGuard

Aevon_FILES = AevonAssertionShim.m \
    AevonPresenterShim.m \
    AevonIdleShim.m \
    AevonOverlayShim.m \
    AevonSceneShim.m \
    Sources/AevonSceneHook.m \
    Sources/AevonTouchHook.m \
    Sources/Aevon.swift \
    Sources/AevonLog.swift \
    Sources/AevonCrashCatcher.swift \
    Sources/AevonPrefs.swift \
    Sources/AevonCrashGuard.swift \
    Sources/AevonBootstrap.swift \
    Sources/AevonEntryHost.swift \
    Sources/AevonEdgeEntry.swift \
    Sources/AevonRingMenu.swift \
    Sources/AevonRingStore.swift \
    Sources/AevonAppList.swift \
    Sources/AevonAppIcon.swift \
    Sources/AevonAppPickerView.swift \
    Sources/AevonRuntime.swift \
    Sources/AevonSwizzle.swift \
    Sources/AevonForegroundManager.swift \
    Sources/AevonAppInfo.swift \
    Sources/AevonAppLayout.swift \
    Sources/AevonSceneHelper.swift \
    Sources/AevonSceneHost.swift \
    Sources/AevonHostWindow.swift \
    Sources/AevonWindowView.swift \
    Sources/AevonSnap.swift \
    Sources/AevonWindowManager.swift \
    Sources/AevonIdleGuard.swift \
    Sources/AevonSwitcherGuard.swift \
    Sources/AevonGestureHandler.swift \
    Sources/Hooks.swift

Aevon_CFLAGS = -fobjc-arc
Aevon_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation

# ─────────────────────────────────────────────────────────────────────
# AevonGuard：只注入前台 App 进程的极小程序（纯 ObjC，不含 Swift）。
# 职责单一：把圆盘热区内按下的那根手指的整条触摸事件丢弃，
# 让 App 自己的横向手势（QQ 左滑删除、抖音左滑进主页）不可能被触发。
# ─────────────────────────────────────────────────────────────────────
AevonGuard_FILES = Sources/AevonAppGuard.m
AevonGuard_CFLAGS = -fobjc-arc
AevonGuard_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation QuartzCore

# ─────────────────────────────────────────────────────────────────────
# V0.0.81（AevonGuardFat81）：Guard 必须是 arm64 + arm64e **双切片**。
#
# Aevon(73) 日志实锤：浮窗里的 GitHub（com.github.stormbreaker.prod）从头到尾
# 没有一条「Guard 已注入」，也没有 /var/mobile/Aevon.alive.com.github... ——
# 那个进程里根本没有 Guard，所以停靠小窗一被轻点就穿透进 App。同机的系统 App
# （设置/Spotlight）和越狱 App（BatteryInfo/Filza）全都有。
#
# 原因：App Store 的 App 主二进制只有 **arm64** 切片，而我们把 ARCHS 写死成
# arm64e —— arm64e 的 dylib 加载进 arm64 进程会被 dyld 判为架构不兼容而
# **静默跳过**（不报错、不写日志，表现就是「这个 App 没有 Guard」）。
# Theos 支持按 target 覆盖架构（instance/rules.mk 的
# `$(THEOS_CURRENT_INSTANCE)_ARCHS`，优先级高于全局 ARCHS），且会自动 lipo
# 合并成 fat 二进制 —— 主 dylib 仍只编 arm64e（只进 SpringBoard），
# deb 架构因此保持 iphoneos-arm64e 不变。
# ─────────────────────────────────────────────────────────────────────
AevonGuard_ARCHS = arm64 arm64e

SUBPROJECTS += AevonPrefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# 输出文件名约定：com.Aevon_<版本>_iphoneos-arm64e.deb
# 注意：dpkg 强制要求 control 里的 Package 只能是小写字母/数字/+-.（大写会被
# dpkg-deb 直接拒绝：package name has characters that aren't lowercase alphanums），
# 因此 Package 保持 com.aevon，仅把「产物文件名」改成大写 A 的 com.Aevon。
# 必须写在 include 之后，才能覆盖 deb.mk 里的默认定义。
_THEOS_DEB_PACKAGE_FILENAME = $(THEOS_PACKAGE_DIR)/com.Aevon_$(_THEOS_INTERNAL_PACKAGE_VERSION)_$(THEOS_PACKAGE_ARCH).deb
