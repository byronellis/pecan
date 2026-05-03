# Pecan Makefile
#
# Use this instead of plain `swift build` — the vm-launcher binary requires the
# com.apple.security.virtualization entitlement (Containerization / vmnet), which
# Swift Package Manager cannot apply.  This Makefile builds all products and signs
# the launcher immediately after, so the binary is always ready to spawn containers.
#
# Targets:
#   make              — release build of all macOS products + Linux agent, then sign
#   make release      — macOS release products + sign (no Linux agent)
#   make agent        — cross-compile pecan-agent for Linux musl only
#   make debug        — debug build + sign (fast iteration)
#   make clean        — swift package clean
#
# Variables (override on the command line):
#   SIGN_IDENTITY     — codesign identity (default: - for ad-hoc)
#                       Set to your Developer ID for distributable builds:
#                       make SIGN_IDENTITY="Developer ID Application: ..."
#   ENTITLEMENTS      — path to entitlements plist (default: Entitlements.plist)

SWIFT         ?= swift
ENTITLEMENTS  ?= Entitlements.plist
SIGN_IDENTITY ?= -

RELEASE_DIR   = .build/arm64-apple-macosx/release
DEBUG_DIR     = .build/arm64-apple-macosx/debug

SIGN = codesign --force --sign "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS)

.PHONY: all release agent debug clean

all: release agent

release:
	$(SWIFT) build -c release \
		--product pecan \
		--product pecan-server \
		--product pecan-vm-launcher
	$(SIGN) $(RELEASE_DIR)/pecan-vm-launcher

agent:
	$(SWIFT) build -c release \
		--product pecan-agent \
		--swift-sdk aarch64-swift-linux-musl

debug:
	$(SWIFT) build \
		--product pecan \
		--product pecan-server \
		--product pecan-vm-launcher
	$(SIGN) $(DEBUG_DIR)/pecan-vm-launcher

clean:
	$(SWIFT) package clean
