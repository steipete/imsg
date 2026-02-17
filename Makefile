SHELL := /bin/bash

.PHONY: help format lint test build imsg clean build-dylib install

help:
	@printf "%s\n" \
		"make format     - swift format in-place" \
		"make lint       - swift format lint + swiftlint" \
		"make test       - sync version, patch deps, run swift test" \
		"make build      - universal release build into bin/" \
		"make build-dylib - build injectable dylib for Messages.app" \
		"make imsg       - clean rebuild + run debug binary (ARGS=...)" \
		"make install    - build release binary and install to /usr/local/bin" \
		"make clean      - swift package clean"

format:
	swift format --in-place --recursive Sources Tests

lint:
	swift format lint --recursive Sources Tests
	swiftlint

test:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift test

build: build-dylib
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	scripts/build-universal.sh

# Build injectable dylib for Messages.app (DYLD_INSERT_LIBRARIES).
# Uses arm64e architecture to match Messages.app on Apple Silicon.
# Requires SIP disabled on the target machine to inject into system apps.
build-dylib:
	@echo "Building imsg-bridge-helper.dylib (injectable)..."
	@mkdir -p .build/release
	@clang -dynamiclib -arch arm64e -fobjc-arc \
		-Wno-arc-performSelector-leaks \
		-framework Foundation \
		-o .build/release/imsg-bridge-helper.dylib \
		Sources/IMsgHelper/IMsgInjected.m
	@echo "Built .build/release/imsg-bridge-helper.dylib"

imsg: build-dylib
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift package clean
	swift build -c debug --product imsg
	./.build/debug/imsg $(ARGS)

clean:
	swift package clean
	@rm -f .build/release/imsg-bridge-helper.dylib

install: build-dylib
	@echo "Building release binary..."
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift build -c release --product imsg
	@echo "Installing imsg to /usr/local/bin..."
	@mkdir -p /usr/local/bin /usr/local/lib
	@cp .build/release/imsg /usr/local/bin/imsg
	@cp .build/release/imsg-bridge-helper.dylib /usr/local/lib/imsg-bridge-helper.dylib
	@echo "Installed. Run 'imsg launch' to enable advanced features."
