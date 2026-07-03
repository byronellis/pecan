# Pecan Makefile
#
# Build targets:
#   make              — release build of all products
#   make release      — release build
#   make debug        — debug build (fast iteration)
#   make clean        — swift package clean
#

SWIFT         ?= swift

.PHONY: all release debug clean

all: release

release:
	$(SWIFT) build -c release --product pecan

debug:
	$(SWIFT) build --product pecan

clean:
	$(SWIFT) package clean
