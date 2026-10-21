ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplitKit

SplitKit_FILES = ctor.m Sources/SplitKit.swift Sources/SKLog.swift Sources/SKPrefs.swift Sources/SKCrashGuard.swift
SplitKit_CFLAGS = -fobjc-arc
SplitKit_FRAMEWORKS = UIKit Foundation CoreGraphics

SUBPROJECTS += splitkitprefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
