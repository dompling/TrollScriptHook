ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

INSTALL_TARGET_PROCESSES = *

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrollScriptHook

TrollScriptHook_FILES = Tweak.x
TrollScriptHook_CFLAGS = -fobjc-arc
TrollScriptHook_FRAMEWORKS = Foundation UserNotifications

include $(THEOS_MAKE_PATH)/tweak.mk
