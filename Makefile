# Original Makefile from YTLite
DEBUG = 0
FINALPACKAGE = 1
ARCHS = arm64
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YouMod
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation AudioToolbox MediaPlayer AVFoundation AVKit Photos CoreGraphics CoreMedia SystemConfiguration Security MobileCoreServices
$(TWEAK_NAME)_WEAK_FRAMEWORKS = UniformTypeIdentifiers
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FILES = $(wildcard Files/*.x)

include $(THEOS_MAKE_PATH)/tweak.mk

# FFmpegKit (full GPL) frameworks, fetched into modules/ffmpeg by
# tools/fetch-ffmpegkit.sh. They are never linked - Download.x dlopens them on
# first use - so a build without them still works (AVFoundation-only downloads).
# The IPA workflow sets YOUMOD_BUNDLE_FFMPEG=0 and injects them into the app's
# Frameworks folder instead, where every sideloading signer re-signs them.
FFMPEGKIT_DIR ?= modules/ffmpeg
YOUMOD_BUNDLE_FFMPEG ?= 1

after-stage::
ifeq ($(YOUMOD_BUNDLE_FFMPEG),1)
	@if [ -f "$(FFMPEGKIT_DIR)/ffmpegkit.framework/ffmpegkit" ]; then \
		bundle="$$(find "$(THEOS_STAGING_DIR)" -type d -name YouMod.bundle -print -quit)"; \
		if [ -z "$$bundle" ]; then echo "error: YouMod.bundle not found in staging" >&2; exit 1; fi; \
		mkdir -p "$$bundle/Frameworks"; \
		cp -R "$(FFMPEGKIT_DIR)"/*.framework "$$bundle/Frameworks/"; \
		echo "==> Staged FFmpegKit into $${bundle#$(THEOS_STAGING_DIR)}/Frameworks"; \
	else \
		echo "==> No FFmpegKit in $(FFMPEGKIT_DIR) - building without bundled FFmpeg"; \
	fi
endif
