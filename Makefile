ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

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
