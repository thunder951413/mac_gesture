.PHONY: build run clean install install-service uninstall-service
.PHONY: service-start service-stop service-status service-logs

BUILD_DIR := .build
EXECUTABLE := $(BUILD_DIR)/debug/GestureDaemon
RELEASE_EXECUTABLE := $(BUILD_DIR)/release/GestureDaemon
BIN_PATH := /usr/local/bin/gesture-daemon
PLIST_LABEL := com.gesturedaemon
PLIST_PATH := $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
LOG_DIR := /tmp

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
	cp $(RELEASE_EXECUTABLE) $(BIN_PATH)
	mkdir -p $(HOME)/.gesture
	chown $(or $(SUDO_USER),$(USER)) $(HOME)/.gesture 2>/dev/null || true
	@echo "已安装到 $(BIN_PATH)"
	@echo ""
	@echo "首次安装后，请先授予辅助功能权限："
	@echo "  系统设置 → 隐私与安全性 → 辅助功能"
	@echo "  添加: $(BIN_PATH)"
	@echo ""
	@echo "配置文件位置: ~/.gesture/config.json"
	@echo "首次运行会自动生成默认配置"
	@echo ""
	@echo "前台运行: gesture-daemon"
	@echo "后台服务: make install-service"

run-install: install
	$(BIN_PATH) $(HOME)/.gesture/config.json

# --- 后台服务（LaunchAgent） ---

install-service: install
	@mkdir -p $(HOME)/Library/LaunchAgents $(HOME)/.gesture
	@chown $(or $(SUDO_USER),$(USER)) $(HOME)/.gesture 2>/dev/null || true
	@if [ ! -f $(HOME)/.gesture/config.json ] && [ -f config.json ]; then \
		cp config.json $(HOME)/.gesture/config.json && \
		echo "已创建默认配置: $(HOME)/.gesture/config.json"; \
		chown $(or $(SUDO_USER),$(USER)) $(HOME)/.gesture/config.json 2>/dev/null || true; \
	fi
	@plutil -create xml1 $(PLIST_PATH) 2>/dev/null; rm -f $(PLIST_PATH)
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'	<key>Label</key>' \
		'	<string>$(PLIST_LABEL)</string>' \
		'	<key>ProgramArguments</key>' \
		'	<array>' \
		'		<string>$(BIN_PATH)</string>' \
		'		<string>$(HOME)/.gesture/config.json</string>' \
		'	</array>' \
		'	<key>RunAtLoad</key>' \
		'	<true/>' \
		'	<key>KeepAlive</key>' \
		'	<true/>' \
		'	<key>StandardOutPath</key>' \
		'	<string>$(LOG_DIR)/gesture-daemon.log</string>' \
		'	<key>StandardErrorPath</key>' \
		'	<string>$(LOG_DIR)/gesture-daemon.err</string>' \
		'	<key>ProcessType</key>' \
		'	<string>Background</string>' \
		'</dict>' \
		'</plist>' > $(PLIST_PATH)
	@plutil -lint $(PLIST_PATH) > /dev/null
	@if launchctl print gui/$(or $(SUDO_UID),$(shell id -u))/$(PLIST_LABEL) >/dev/null 2>&1; then \
		echo "服务已注册，正在重新启动..."; \
		launchctl kickstart -p gui/$(or $(SUDO_UID),$(shell id -u))/$(PLIST_LABEL); \
	else \
		launchctl bootstrap gui/$(or $(SUDO_UID),$(shell id -u)) $(PLIST_PATH); \
	fi
	@echo ""
	@echo "✅ 服务已安装并启动"
	@echo "   二进制: $(BIN_PATH)"
	@echo "   plist:  $(PLIST_PATH)"
	@echo "   配置:   $(HOME)/.gesture/config.json"
	@echo "   日志:   $(LOG_DIR)/gesture-daemon.log"
	@echo "           $(LOG_DIR)/gesture-daemon.err"

uninstall-service:
	launchctl bootout gui/$(or $(SUDO_UID),$(shell id -u)) $(PLIST_PATH) 2>/dev/null || launchctl unload $(PLIST_PATH) 2>/dev/null || true
	rm -f $(PLIST_PATH)
	@echo "✅ 服务已卸载"

service-start:
	@if [ "$(shell id -u)" = "0" ]; then \
		echo "❌ 错误: service-start 不需要 sudo，launchctl gui 域属于当前用户"; \
		echo "   请直接运行: make service-start"; \
		exit 1; \
	fi
	@if launchctl print gui/$(shell id -u)/$(PLIST_LABEL) >/dev/null 2>&1; then \
		echo "服务已注册，正在启动..."; \
		launchctl kickstart -p gui/$(shell id -u)/$(PLIST_LABEL); \
	else \
		echo "正在注册服务..."; \
		launchctl bootstrap gui/$(shell id -u) $(PLIST_PATH); \
	fi

service-stop:
	@if [ "$(shell id -u)" = "0" ]; then \
		echo "❌ 错误: service-stop 不需要 sudo"; \
		echo "   请直接运行: make service-stop"; \
		exit 1; \
	fi
	-launchctl bootout gui/$(shell id -u) $(PLIST_PATH) 2>/dev/null
	@echo "服务已停止"

service-status:
	@echo "--- launchctl 状态 ---"
	launchctl print gui/$(shell id -u)/$(PLIST_LABEL) 2>&1 || echo "服务未加载"
	@echo ""
	@echo "--- 进程检查 ---"
	ps aux | grep -v grep | grep gesture-daemon || echo "进程未运行"

service-logs:
	@echo "=== 标准输出日志 (gesture-daemon.log) ==="
	@if [ -f $(LOG_DIR)/gesture-daemon.log ]; then tail -30 $(LOG_DIR)/gesture-daemon.log; else echo "(暂无日志)"; fi
	@echo ""
	@echo "=== 错误日志 (gesture-daemon.err) ==="
	@if [ -f $(LOG_DIR)/gesture-daemon.err ]; then tail -30 $(LOG_DIR)/gesture-daemon.err; else echo "(暂无日志)"; fi
