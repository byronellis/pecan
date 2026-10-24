# Pecan build.
#
# Every build embeds a version, build number and channel in the executable's
# __TEXT,__info_plist section (read back by Sources/PecanSettings/BuildInfo.swift). Clients use
# them to decide whether to replace a running server with their own, newer build.
#
#   make / make debug          debug build, dev channel
#   make release               optimized build, dev channel
#   make dist BUILD_NUMBER=n   optimized build, release channel (CI: n = CI run number)
#   make run [ARGS="..."]      debug build, then run it (e.g. ARGS="server status")
#   make clean                 swift package clean
#
# Dev builds are numbered by a per-user counter in ~/.pecan-dev/build-counter that every dev
# build increments; it lives outside the repo and .build so cleans and branch switches never
# reset it. Release builds take the CI run number, which is already monotonic.
#
# A plain `swift build` still works; it produces an unversioned dev build.

SHELL := /bin/bash

VERSION := $(shell cat VERSION)
GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)
DEV_COUNTER := $(HOME)/.pecan-dev/build-counter
INFO_PLIST := .build/pecan-info/Info.plist
PRODUCT := pecan

.PHONY: all debug release dist run clean

all: debug

debug: CONFIG := debug
debug: CHANNEL := dev
release: CONFIG := release
release: CHANNEL := dev
dist: CONFIG := release
dist: CHANNEL := release

# The plist is a linker input SwiftPM does not track, so the recipe deletes the binary to force
# a relink that picks up the new build number. macOS ships GNU Make 3.81, which ignores
# .SHELLFLAGS, so the recipe sets its own error handling.
debug release dist:
	@set -euo pipefail; \
	if [ "$(CHANNEL)" = release ]; then \
		[ -n "$(BUILD_NUMBER)" ] || { echo "make dist requires BUILD_NUMBER (e.g. the CI run number)" >&2; exit 1; }; \
		build="$(BUILD_NUMBER)"; \
	else \
		mkdir -p "$(dir $(DEV_COUNTER))"; \
		build=$$(( $$(cat "$(DEV_COUNTER)" 2>/dev/null || echo 0) + 1 )); \
		echo "$$build" > "$(DEV_COUNTER)"; \
	fi; \
	mkdir -p "$(dir $(INFO_PLIST))"; \
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>CFBundleIdentifier</key><string>dev.pecan.cli</string>' \
		'<key>CFBundleName</key><string>pecan</string>' \
		"<key>CFBundleShortVersionString</key><string>$(VERSION)</string>" \
		"<key>CFBundleVersion</key><string>$$build</string>" \
		'<key>PecanChannel</key><string>$(CHANNEL)</string>' \
		'<key>PecanGitHash</key><string>$(GIT_HASH)</string>' \
		'</dict></plist>' > "$(INFO_PLIST)"; \
	plutil -lint -s "$(INFO_PLIST)"; \
	rm -f "$$(swift build -c $(CONFIG) --show-bin-path)/$(PRODUCT)"; \
	swift build -c $(CONFIG) --product $(PRODUCT) \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$(abspath $(INFO_PLIST))"; \
	echo "Built $(PRODUCT) $(VERSION) ($(CHANNEL) build $$build, $(GIT_HASH)) -> $$(swift build -c $(CONFIG) --show-bin-path)/$(PRODUCT)"

# Every run is a new build, so it also replaces the running dev server with this one.
run: debug
	@exec "$$(swift build -c debug --show-bin-path)/$(PRODUCT)" $(ARGS)

clean:
	swift package clean
