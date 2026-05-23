ARCHS = arm64
TARGET = appletv:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TwitchAdBlock
TwitchAdBlock_FILES = Tweak.m
TwitchAdBlock_CFLAGS = -fobjc-arc
TwitchAdBlock_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
