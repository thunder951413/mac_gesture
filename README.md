# GestureDaemon

macOS 触控板手势 + 键盘热键映射引擎。

通过触控板手势（多指滑动/捏合）或键盘组合键触发自定义按键序列，发送到当前活跃 App。

> macOS 13+ | Swift | CoreGraphics | MultitouchSupport.framework

---

## 功能

- **触控板手势识别** — 多指滑动方向、捏合/张开检测，映射为任意按键
- **键盘热键重映射** — 监听组合键，拦截并替换为其他按键
- **多策略设备注册** — 兼容 macOS 13–26 各版本 MultitouchSupport 框架

---

## 架构

```
┌──────────────────────────────────────────────────────┐
│                    GestureDaemon                      │
│  ├── TouchListener  ← MultitouchSupport.framework    │
│  ├── GestureRecognizer  → 方向/距离/指数量化          │
│  ├── HotkeyListener   ← CGEventTap                   │
│  ├── KeySimulator     → CGEventPost (.cghidEventTap) │
│  └── Config           ← config.json                  │
└──────────────────────────────────────────────────────┘
```

### 模块说明

| 文件 | 职责 |
|------|------|
| `main.swift` | 入口：信号处理、配置加载、启动守护进程 |
| `GestureDaemon.swift` | 主控制器：编排 TouchListener + HotkeyListener |
| `Config.swift` | 配置模型：GestureMapping、HotkeyMapping |
| `TouchListener.swift` | 通过私有框架 MultitouchSupport 接收触控板原始触摸数据 |
| `GestureRecognizer.swift` | 识别手势：指数量、滑动方向、距离、捏合/张开 |
| `HotkeyListener.swift` | 通过 CGEventTap 拦截键盘事件，匹配热键规则并替换 |
| `KeySimulator.swift` | 通过 CGEvent 发送按键事件到当前 App |

---

## 快速开始

### 1. 编译

```bash
make build      # debug 构建
make release    # release 构建
```

### 2. 运行

```bash
make run        # 使用 config.json
# 或指定配置:
swift run config.json
```

### 3. 设置权限

首次运行需要授予**辅助功能权限**：

```
系统设置 → 隐私与安全性 → 辅助功能
  → 将 Terminal.app（或编译后的二进制）添加到列表
  → 重新运行
```

### 4. 安装（可选）

```bash
make install    # 安装到 /usr/local/bin/gesture-daemon
gesture-daemon config.json
```

---

## 配置

编辑 `config.json`，包含手势映射与热键映射两大部分。

### 手势映射 `gestures`

```json
{
  "gestures": [
    {
      "name": "三指下滑关闭窗口",
      "fingers": 3,
      "direction": "down",
      "minDistance": 0.15,
      "keys": ["cmd", "w"]
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | String | 映射名称（仅用于日志） |
| `fingers` | Int | 手指数量（2–5） |
| `direction` | String | 方向：`up` `down` `left` `right` `pinch` `spread` |
| `minDistance` | Double | 最小触发距离（0.0–1.0），避免误触 |
| `keys` | [String] | 触发的按键序列 |

### 热键映射 `hotkeys`

```json
{
  "hotkeys": [
    {
      "name": "Ctrl+Shift+A → Cmd+C",
      "when": ["ctrl", "shift", "a"],
      "send": ["cmd", "c"]
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | String | 映射名称（仅用于日志） |
| `when` | [String] | 触发组合键：修饰键 + 一个普通键 |
| `send` | [String] | 替换发送的按键序列 |

### 通用设置 `settings`

```json
{
  "settings": {
    "debounceMs": 300,
    "logLevel": "info"
  }
}
```

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `debounceMs` | Int | 300 | 防抖毫秒数，同一映射在此时间内不会重复触发 |
| `logLevel` | String | "info" | 日志级别：`info` `debug` |

### 支持的按键名称

**修饰键：** `cmd` `command` `shift` `option` `opt` `alt` `ctrl` `control` `fn` `function`

**普通键：** `a`–`z` `0`–`9` `space` `return` `enter` `tab` `delete` `backspace` `escape` `esc`
`f1`–`f12` `left` `right` `up` `down` `home` `end` `pageup` `pagedown` `-` `=` `[` `]` `\` `;` `'` `,` `.` `/` `` ` ``

---

## 触控板手势说明

### 支持的识别

| 手势 | 示例 |
|------|------|
| 2–5 指向一个方向滑动 | 三指下滑、四指上滑 |
| 捏合 / 张开（4指以上） | 五指捏合显示桌面 |

手势识别基于触控板坐标归一化值，通过计算质心位移方向和距离来判断。

### 调试模式

```json
{
  "settings": { "logLevel": "debug" }
}
```

在 debug 级别下，每次手势识别都会输出手指数和方向：

```
[Gesture] 3指 down 距离:0.234
```

---

## 构建与安装

### 命令

| 命令 | 说明 |
|------|------|
| `make build` | Debug 构建 |
| `make release` | Release 构建 |
| `make run` | Debug 构建并运行 |
| `make run-release` | Release 构建并运行 |
| `make install` | 安装到 `/usr/local/bin/gesture-daemon` |
| `make clean` | 清理构建产物 |

### 系统要求

- macOS 13+
- 触控板（MacBook 内置或 Magic Trackpad）
- 辅助功能权限（用于发送按键 + 创建 EventTap）

---

## 服务管理（后台运行 + 开机自启）

将 GestureDaemon 安装为 **LaunchAgent**，后台静默运行、开机自动启动。

### 安装服务

```bash
make install-service
```

这个命令会：
1. Release 构建并安装到 `/usr/local/bin/gesture-daemon`
2. 创建 `~/Library/LaunchAgents/com.gesturedaemon.plist`
3. 通过 `launchctl` 注册并启动服务
4. 日志输出到 `/tmp/gesture-daemon.log` 和 `/tmp/gesture-daemon.err`

首次使用需授予辅助功能权限：

```
系统设置 → 隐私与安全性 → 辅助功能
  → 添加: /usr/local/bin/gesture-daemon
  → 添加后重启服务: make service-stop && make service-start
```

### 管理命令

| 命令 | 说明 |
|------|------|
| `make service-status` | 查看服务运行状态 |
| `make service-logs` | 查看最近日志 |
| `make service-start` | 启动服务 |
| `make service-stop` | 停止服务 |
| `make install-service` | 安装并启动服务 |
| `make uninstall-service` | 卸载服务 |

### 直接管理（底层）

如果偏好手动管理，也可以直接用 launchctl：

```bash
# 加载
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gesturedaemon.plist

# 卸载
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.gesturedaemon.plist

# 查看状态
launchctl print gui/$(id -u)/com.gesturedaemon
```

---

## 常见问题

### 启动失败：注册失败

```
[GestureDaemon] 启动失败: 注册失败。如需重置触控板驱动状态请重启电脑
```

MultitouchSupport 框架回调注册失败。解决办法（按优先级）：
1. **重启电脑** — 重置触控板驱动内部状态
2. **重新插拔外接触控板** — 如果是 Magic Trackpad

### 触控板无响应

1. 确认触控板已连接并正常工作
2. 检查是否有其他软件也在占用触控板事件流
3. 尝试重启电脑

### 热键监听器启动失败

```
[HotkeyListener] ❌ EventTap 创建失败，热键功能不可用
```

需要辅助功能权限：

```
系统设置 → 隐私与安全性 → 辅助功能
  → 添加本程序（或 Terminal）
```

授权后重新启动。

### 按键未发送到目标 App

确保已在系统设置中授予**辅助功能权限**。该权限是 `CGEvent.post` 和 `CGEvent.tapCreate` 所必需的。

### 热键触发后无限循环

`HotkeyListener` 通过检查事件源的进程 ID 来防止循环——`KeySimulator` 发出的按键携带当前进程的 PID，`HotkeyListener` 会跳过来自本进程的事件。

---

## 技术细节

### MultitouchSupport 私有框架

通过 `dlopen` 动态加载，`dlsym` 解析符号，避免静态链接私有框架导致的兼容性问题。

回调签名（macOS 14+）：

```c
int callback(MTDeviceRef device, MTFinger *fingers, int count, double timestamp, int frame);
```

注册流程：`MTRegisterContactFrameCallback` → `MTDeviceStart`（**必须先注册再启动**）。

### CGEventTap

热键拦截使用 `CGEvent.tapCreate` 在系统事件队列头部插入监听点，在事件到达目标 App 之前完成拦截和替换。

### CGEvent 发键

`KeySimulator` 使用 `CGEventSource(stateID: .hidSystemState)` 创建事件源，确保发出的按键携带正确的进程 ID，用于防循环检测。

---

## License

MIT
