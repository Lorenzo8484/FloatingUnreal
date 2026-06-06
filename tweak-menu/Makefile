THEOS_DEVICE_IP ?= 127.0.0.1
THEOS_DEVICE_PORT ?= 22

TARGET := iphone:clang:latest:14.0
ARCHS = arm64

INSTALL_TARGET_PROCESSES = $(TARGET_APP)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingUnreal

FloatingUnreal_FILES  = Tweak.mm FloatingMenu.mm ShaderPage.mm
FloatingUnreal_CFLAGS = -fobjc-arc
FloatingUnreal_FRAMEWORKS = UIKit Foundation Metal

include $(THEOS)/makefiles/tweak.mk
