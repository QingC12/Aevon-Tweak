include $(THEOS)/makefiles/common.mk

# 与主工程一致：只产 arm64e 切片（否则子工程会默认编成 arm64+arm64e fat）
ARCHS = arm64e

BUNDLE_NAME = AevonPrefs
AevonPrefs_FILES = AevonPrefs.m AevonRingEditorController.m
AevonPrefs_CFLAGS = -fobjc-arc
AevonPrefs_FRAMEWORKS = UIKit
AevonPrefs_PRIVATE_FRAMEWORKS = Preferences
AevonPrefs_INSTALL_PATH = /Library/PreferenceBundles

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AevonPrefs.plist$(ECHO_END)

include $(THEOS_MAKE_PATH)/bundle.mk
