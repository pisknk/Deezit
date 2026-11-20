# Deezit - slowed + reverb (and more) for Deezer iOS, no jailbreak.
#
# The dylib is injected into a decrypted Deezer IPA (e.g. with cyan) and
# sideloaded, so there is no Substrate/ElleKit on device: Logos uses the
# "internal" generator (plain ObjC runtime swizzling) and nothing links
# CydiaSubstrate. The audio backend (AVAudioEngine, see docs/ANALYSIS.md) is
# all ObjC hooks, so no fishhook either. CI checks the built dylib has no
# Substrate/ElleKit dependency.

TARGET := iphone:clang:latest:15.0
# Third-party processes run the plain arm64 slice (App Store apps are not
# arm64e), so a sideloaded Deezer never loads an arm64e slice.
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Deezer

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Deezit

Deezit_FILES = Tweak.x \
	DZDebugLog.m \
	DZPrefs.m \
	DZPresets.m \
	DZDSP.c \
	DZVocals.c \
	DZVocalUnit.m \
	DZAudioHook.x \
	DZBufferProbe.x \
	DZProbes.x \
	DZPlayerMenu.x \
	DZAppleMusic.m \
	DZMotionFile.m \
	DZLockArtwork.x \
	DZSettingsViewController.m \
	DZDebugViewController.m \
	DZSettingsEntry.m
Deezit_FRAMEWORKS = UIKit QuartzCore AVFoundation AudioToolbox MediaPlayer
DEEZIT_VERSION := $(shell sed -n 's/^Version: //p' control)
Deezit_CFLAGS = -fobjc-arc -Wall -Wno-deprecated-declarations -DDEEZIT_VERSION=\"$(DEEZIT_VERSION)\"
Deezit_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/tweak.mk
