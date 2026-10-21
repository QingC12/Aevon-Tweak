include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SplitKitPrefs
SplitKitPrefs_FILES = SplitKitPrefs.m
SplitKitPrefs_FRAMEWORKS = UIKit
SplitKitPrefs_PRIVATE_FRAMEWORKS = Preferences
SplitKitPrefs_INSTALL_PATH = /Library/PreferenceBundles

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/SplitKitPrefs.plist$(ECHO_END)

include $(THEOS_MAKE_PATH)/bundle.mk
