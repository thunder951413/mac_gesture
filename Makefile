.PHONY: build run clean install

BUILD_DIR := .build
EXECUTABLE := $(BUILD_DIR)/debug/GestureDaemon
RELEASE_EXECUTABLE := $(BUILD_DIR)/release/GestureDaemon

build:
	swift build

release:
	swift build -c release

run: build
	$(EXECUTABLE) config.json

run-release: release
	$(RELEASE_EXECUTABLE) config.json

clean:
	swift package clean
	rm -rf $(BUILD_DIR)

install: release
	cp $(RELEASE_EXECUTABLE) /usr/local/bin/gesture-daemon
	@echo "已安装到 /usr/local/bin/gesture-daemon"
	@echo "运行方式: gesture-daemon [config.json]"
