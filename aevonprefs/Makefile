include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AevonPrefs
AevonPrefs_FILES = AevonPrefs.m
AevonPrefs_FRAMEWORKS = UIKit
AevonPrefs_PRIVATE_FRAMEWORKS = Preferences
AevonPrefs_INSTALL_PATH = /Library/PreferenceBundles

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AevonPrefs.plist$(ECHO_END)

include $(THEOS_MAKE_PATH)/bundle.mk
