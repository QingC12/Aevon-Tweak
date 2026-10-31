# 打包约定（勿随意更改）
#   ARCHS                 = arm64e                 设备 A17，只产 arm64e 切片
#   THEOS_PACKAGE_SCHEME  = roothide               roothide 布局，deb 架构 iphoneos-arm64e
#   Theos 来源            = roothide/theos         上游 theos 不支持 roothide scheme
#   签名                  = Procursus ldid -S      占位签名（.unsigned）在 roothide 上会崩 SpringBoard
ARCHS = arm64e
TARGET := iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Aevon AevonApp

Aevon_FILES = AevonAssertionShim.m \
    AevonPresenterShim.m \
    AevonSceneDriverShim.m \
    Sources/AevonSceneHook.m \
    Sources/AevonProbeSupport.m \
    Sources/AevonTouchHook.m \
    Sources/AevonGripHook.m \
    Sources/AevonGripAssert.m \
    Sources/AevonKeepAliveProbe.m \
    Sources/AevonSnapProbe.m \
    Sources/AevonSceneCensus.m \
    Sources/AevonSceneWriteGuard.m \
    Sources/Aevon.swift \
    Sources/AevonLog.swift \
    Sources/AevonCrashCatcher.swift \
    Sources/AevonPrefs.swift \
    Sources/AevonCrashGuard.swift \
    Sources/AevonBootstrap.swift \
    Sources/AevonEntryHost.swift \
    Sources/AevonEdgeEntry.swift \
    Sources/AevonRingMenu.swift \
    Sources/AevonHoverKeyframes.swift \
    Sources/AevonRingUnfold.swift \
    Sources/AevonSpring.swift \
    Sources/AevonFloatMotion.swift \
    Sources/AevonRingStore.swift \
    Sources/AevonAppList.swift \
    Sources/AevonAppIcon.swift \
    Sources/AevonAppPickerView.swift \
    Sources/AevonRuntime.swift \
    Sources/AevonSwizzle.swift \
    Sources/AevonForegroundManager.swift \
    Sources/AevonWriteGuard.swift \
    Sources/AevonAppInfo.swift \
    Sources/AevonAppLayout.swift \
    Sources/AevonSceneHelper.swift \
    Sources/AevonSceneLedger.swift \
    Sources/AevonSettingsChannel.swift \
    Sources/AevonSwitchTransaction.swift \
    Sources/AevonSceneHost.swift \
    Sources/AevonHostWindow.swift \
    Sources/AevonWindowView.swift \
    Sources/AevonDock.swift \
    Sources/AevonRingGrip.swift \
    Sources/AevonWindowManager.swift \
    Sources/AevonGestureHandler.swift \
    Sources/AevonAppSideBridge.swift \
    Sources/AevonQuickAction.swift \
    Sources/AevonRecProbe.swift \
    Sources/Hooks.swift

Aevon_CFLAGS = -fobjc-arc
# V0.2.62（AevonQuickActionV262）：圆盘的「录屏」用 ReplayKit，「截图」存相册用 Photos。
Aevon_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation ReplayKit Photos

# ---------------------------------------------------------------------------
# 第二个 dylib：AevonApp
#
# 只有它会被注入第三方 App 进程（filter 见 AevonApp.plist，V0.2.0 只列
# 设置 / Safari 两个）。把它独立成一个 tweak 而不是并进 Aevon，是为了保证
# 主插件那 600KB（窗口、场景、圆盘、探针）永远不会进别人的 App 进程 ——
# App 侧只有「读配置 + 挂一个只读识别器 + 写自己的偏好域」这一件事。
#
# 用 ObjC 而不是 Swift：App 侧要碰 `UIApplication.sharedApplication`、
# 遍历 `connectedScenes`、读 CFPreferences 跨域，这些正是 Swift 在
# `swift_dynamicCast` 上出现 SIGTRAP 的历史位置（归档(13) 的探针事故）。
# 200 行以内用 ObjC 写，异常可以 @try 兜住，也是主插件一直采用的「垫片」形态。
# ---------------------------------------------------------------------------
AevonApp_FILES = Sources/AppSide/AevonAppSide.m
AevonApp_CFLAGS = -fobjc-arc
AevonApp_FRAMEWORKS = UIKit Foundation CoreFoundation

SUBPROJECTS += AevonPrefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# 输出文件名约定：com.Aevon_<版本>_iphoneos-arm64e.deb
# 注意：dpkg 强制要求 control 里的 Package 只能是小写字母/数字/+-.（大写会被
# dpkg-deb 直接拒绝：package name has characters that aren't lowercase alphanums），
# 因此 Package 保持 com.aevon，仅把「产物文件名」改成大写 A 的 com.Aevon。
# 必须写在 include 之后，才能覆盖 deb.mk 里的默认定义。
_THEOS_DEB_PACKAGE_FILENAME = $(THEOS_PACKAGE_DIR)/com.Aevon_$(_THEOS_INTERNAL_PACKAGE_VERSION)_$(THEOS_PACKAGE_ARCH).deb
