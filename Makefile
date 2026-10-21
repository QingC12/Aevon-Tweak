# 打包约定（勿随意更改）
#   ARCHS                 = arm64e                 设备 A17，只产 arm64e 切片
#   THEOS_PACKAGE_SCHEME  = roothide               roothide 布局，deb 架构 iphoneos-arm64e
#   Theos 来源            = roothide/theos         上游 theos 不支持 roothide scheme
#   签名                  = Procursus ldid -S      占位签名（.unsigned）在 roothide 上会崩 SpringBoard
ARCHS = arm64e
TARGET := iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplitKit

SplitKit_FILES = ctor.m AssertionShim.m \
    Sources/SplitKit.swift \
    Sources/SKLog.swift \
    Sources/SKPrefs.swift \
    Sources/SKCrashGuard.swift \
    Sources/SKRuntime.swift \
    Sources/SKSwizzle.swift \
    Sources/SKForegroundManager.swift \
    Sources/SKAppInfo.swift \
    Sources/SKAppLayout.swift \
    Sources/SKSceneHelper.swift \
    Sources/SKHostWindow.swift \
    Sources/SKWindowView.swift \
    Sources/SKWindowManager.swift \
    Sources/SKGestureHandler.swift \
    Sources/Hooks.swift

SplitKit_CFLAGS = -fobjc-arc
SplitKit_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation

SUBPROJECTS += splitkitprefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
