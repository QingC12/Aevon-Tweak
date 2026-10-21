# 打包约定（勿随意更改）
#   ARCHS                 = arm64e                 设备 A17，只产 arm64e 切片
#   THEOS_PACKAGE_SCHEME  = roothide               roothide 布局，deb 架构 iphoneos-arm64e
#   Theos 来源            = roothide/theos         上游 theos 不支持 roothide scheme
#   签名                  = Procursus ldid -S      占位签名（.unsigned）在 roothide 上会崩 SpringBoard
ARCHS = arm64e
TARGET := iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Aevon

Aevon_FILES = AEAssertionShim.m \
    Sources/Aevon.swift \
    Sources/AELog.swift \
    Sources/AEPrefs.swift \
    Sources/AECrashGuard.swift \
    Sources/AERuntime.swift \
    Sources/AESwizzle.swift \
    Sources/AEForegroundManager.swift \
    Sources/AEAppInfo.swift \
    Sources/AEAppLayout.swift \
    Sources/AESceneHelper.swift \
    Sources/AEHostWindow.swift \
    Sources/AEWindowView.swift \
    Sources/AEWindowManager.swift \
    Sources/AEGestureHandler.swift \
    Sources/Hooks.swift

Aevon_CFLAGS = -fobjc-arc
Aevon_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation

SUBPROJECTS += aevonprefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
