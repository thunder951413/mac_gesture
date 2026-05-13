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
	mkdir -p ~/.gesture
	@echo "已安装到 /usr/local/bin/gesture-daemon"
	@echo ""
	@echo "首次安装后，请先授予辅助功能权限："
	@echo "  系统设置 → 隐私与安全性 → 辅助功能"
	@echo "  添加: /usr/local/bin/gesture-daemon"
	@echo ""
	@echo "配置文件位置: ~/.gesture/config.json"
	@echo "首次运行会自动生成默认配置"
	@echo ""
	@echo "运行方式: gesture-daemon"

run-install: install
	/usr/local/bin/gesture-daemon
