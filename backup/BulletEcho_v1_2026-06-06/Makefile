TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = bulletecho
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = FloatingUnreal
FloatingUnreal_FILES  = Tweak.mm FloatingMenu.mm ShaderPage.mm
FloatingUnreal_CFLAGS = -fobjc-arc
FloatingUnreal_FRAMEWORKS = UIKit Foundation Metal
include $(THEOS)/makefiles/tweak.mk
