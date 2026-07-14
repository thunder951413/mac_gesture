.PHONY: build release run run-release clean bundle run-app install install-app test

BUILD_DIR := .build
EXECUTABLE := $(BUILD_DIR)/debug/GestureDaemon
RELEASE_EXECUTABLE := $(BUILD_DIR)/release/GestureDaemon
TOUCH_SERVICE := $(BUILD_DIR)/release/GestureTouchService
APP_NAME := Gesture.app
APP_BUNDLE := dist/$(APP_NAME)
XCODE_DEVELOPER_DIR := $(firstword $(wildcard /Applications/Xcode.app/Contents/Developer) $(shell xcode-select -p))
SWIFT := DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) swift
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | head -1)
CODESIGN_SIGN := $(if $(CODESIGN_IDENTITY),$(CODESIGN_IDENTITY),-)

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

run: build
	$(EXECUTABLE)

run-release: release
	$(RELEASE_EXECUTABLE)

test:
	$(SWIFT) test

bundle: release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Helpers $(APP_BUNDLE)/Contents/Resources
	cp $(RELEASE_EXECUTABLE) $(APP_BUNDLE)/Contents/MacOS/GestureDaemon
	cp $(TOUCH_SERVICE) $(APP_BUNDLE)/Contents/Helpers/GestureTouchService
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	chmod +x $(APP_BUNDLE)/Contents/MacOS/GestureDaemon $(APP_BUNDLE)/Contents/Helpers/GestureTouchService
	codesign --force --options runtime --timestamp=none --sign "$(CODESIGN_SIGN)" $(APP_BUNDLE)/Contents/Helpers/GestureTouchService
	codesign --force --deep --options runtime --timestamp=none --sign "$(CODESIGN_SIGN)" $(APP_BUNDLE)

run-app: bundle
	open $(APP_BUNDLE)

install: install-app

install-app: bundle
	rm -rf /Applications/$(APP_NAME)
	cp -R $(APP_BUNDLE) /Applications/$(APP_NAME)
	@echo "已安装到 /Applications/$(APP_NAME)"
	@echo "首次运行后请在系统设置中授予辅助功能权限"

clean:
	swift package clean
	rm -rf $(BUILD_DIR) dist
