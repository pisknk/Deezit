# Deezit - slowed + reverb (and more) for Deezer iOS, no jailbreak.
#
# The dylib is injected into a decrypted Deezer IPA (e.g. with cyan) and
# sideloaded, so there is no Substrate/ElleKit on device: Logos uses the
# "internal" generator (plain ObjC runtime swizzling) and nothing links
# CydiaSubstrate. C-function hooks (if the audio path needs them) will use a
# vendored fishhook, added once the analysis picks the backend.

TARGET := iphone:clang:latest:15.0
# Third-party processes run the plain arm64 slice (App Store apps are not
# arm64e), so a sideloaded Deezer never loads an arm64e slice.
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Deezer

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Deezit

Deezit_FILES = Tweak.x \
	DZPrefs.m \
	DZPresets.m \
	DZDSP.c \
	DZAudioHook.m \
	DZSettingsViewController.m \
	DZSettingsEntry.m
Deezit_FRAMEWORKS = UIKit AVFoundation AudioToolbox
DEEZIT_VERSION := $(shell sed -n 's/^Version: //p' control)
Deezit_CFLAGS = -fobjc-arc -Wall -Wno-deprecated-declarations -DDEEZIT_VERSION=\"$(DEEZIT_VERSION)\"
Deezit_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/tweak.mk
