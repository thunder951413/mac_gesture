# Gesture

Gesture 是一个原生 macOS 触控板手势与组合键自动化工具。它以菜单栏应用运行，通过可视化界面创建“触发器 → App 范围 → 动作”规则，不再需要手动编辑配置文件。

## 功能

- 2–5 指上、下、左、右滑动，以及 4–5 指捏合/张开
- 捏合允许拇指相对固定或中心点同时偏移，避免被提前判为滑动
- 全局组合键重映射，支持按下/松开触发和按键连发策略
- 规则可限定为所有 App、仅指定 App 或排除指定 App
- 一条规则可以依次执行多个动作
- 支持发送快捷键、打开网址、打开应用、Shell、AppleScript 和延时
- 菜单栏启停、运行状态、辅助功能权限诊断
- 私有触控板读取运行在独立辅助进程中，异常不会带崩主应用
- 辅助进程异常时自动重启一次，再自动切换到公开 API 兼容模式
- 可手动强制兼容模式，完全不加载私有触点框架
- 规则冲突、空动作和无效快捷键配置诊断
- 检测快捷键别名、按下/松开规则和 App 范围重叠造成的触发冲突
- 规则优先级可通过工具栏上移、下移调整
- 状态页实时显示最近触点、最近识别结果和最近触发规则
- 诊断日志保存到 `~/Library/Logs/Gesture/gesture.log`
- 旧版 `gestures/hotkeys/settings` JSON 自动迁移到 schema v2
- 配置原子保存到 `~/.gesture/config.json`，保存后立即热应用

界面结构参考了 BetterTouchTool 的全局/App 专属触发器组织方式，以及 Keyboard Maestro 的触发器与动作分层：

- [BetterTouchTool: Global and App-Specific Triggers](https://docs.folivora.ai/docs/configuration/global-vs-app-specific/)
- [BetterTouchTool: Basic Preferences Overview](https://docs.folivora.ai/docs/configuration/basic-overview/)
- [Keyboard Maestro: Triggers](https://wiki.keyboardmaestro.com/Triggers)

## 构建与运行

要求 macOS 13 或更新版本，以及 Swift 5.9 或更新版本。

```bash
make build       # Debug 编译
make test        # 运行回归测试
make verify      # 测试、Release 打包、严格签名验证和 Info.plist 检查
make run         # 直接运行 Debug 版本
make bundle      # 生成 dist/Gesture.app
make run-app     # 构建并打开 app
make install-app # 安装到 /Applications/Gesture.app
```

安装后，在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Gesture。全局按键监听和按键模拟都依赖此权限。

打包时会优先使用钥匙串中可用的 Apple Development 签名，使辅助功能授权在后续本地重新构建时保持稳定；没有可用证书时才回退到临时签名。

## 使用

1. 打开 Gesture 设置窗口。
2. 在左侧选择“触控板”或“键盘”，点击工具栏 `+` 新建规则。
3. 设置触发手势或直接录制快捷键。
4. 可选：将规则限制到指定应用。
5. 添加一个或多个动作。
6. 点击“保存并应用”。

列表靠前的匹配规则优先执行，可使用工具栏的上、下箭头调整优先级。编辑规则和识别参数后，需要点击“保存并应用”；Dock 和菜单栏外观开关会立即保存对应选项，其他尚未保存的编辑会保留。录制快捷键时会暂停规则拦截，再次点击录制按钮可以取消；切换到其他应用也会结束录制。

“测试动作”会直接执行当前编辑的动作，即使引擎已停止或规则限定了其他 App。快捷键动作发送到当前前台应用。动作按顺序运行；前一步失败会停止该序列并在状态页显示原因。停止或重新应用引擎会取消排队动作和等待，并终止正在运行的脚本进程。每个命令最多运行 60 秒，队列最多保留 32 个动作序列，超限会显示诊断提示。

菜单栏手掌图标可以停止/启动引擎、查看最近触发并重新打开设置窗口。

## 配置格式

配置由程序管理，仍使用可移植的 JSON：

```json
{
  "schemaVersion": 2,
  "rules": [
    {
      "id": "7C278BCE-C3E6-48D4-A736-B282A70864D9",
      "name": "三指下滑关闭窗口",
      "isEnabled": true,
      "trigger": {
        "type": "trackpad",
        "trackpad": {
          "fingers": 3,
          "direction": "down",
          "minimumDistance": 0.22
        }
      },
      "applicationScope": {
        "mode": "all",
        "bundleIdentifiers": []
      },
      "actions": [
        {
          "id": "B9F413F0-F16E-4476-91F4-7F7F46A14C34",
          "kind": "keyboardShortcut",
          "keys": ["cmd", "w"],
          "value": "",
          "delayMilliseconds": 250
        }
      ]
    }
  ],
  "settings": {}
}
```

正常使用无需手工修改。写入无效 JSON 时，程序不会覆盖原文件，而会载入内置默认配置。

程序拒绝未知配置版本和重复的规则/动作 ID；这些文件也会原样保留。配置读取失败时，外观自动保存不会覆盖原文件，只有明确点击“保存并应用”才会将当前配置写回。通过 `GESTURE_CONFIG_PATH=/absolute/path/config.json` 可以指定独立配置，便于开发和验证。

## 架构

```text
TrackpadInput ─┐
               ├─> GestureDaemon / Rule matching ─> ActionExecutor
KeyboardInput ─┘               │
                               └─> ApplicationScope

SwiftUI settings <─> ConfigurationStore <─> ~/.gesture/config.json

Gesture.app ── JSON Lines ──> GestureTouchService ──> MultitouchSupport
      └─────────────────────> Public NSEvent fallback
```

主要模块：

- `AutomationModels.swift`：schema v2 规则、触发器、范围和动作模型
- `ConfigurationStore.swift`：加载、旧配置迁移、原子保存
- `TouchListener.swift` / `MTContactDecoder.swift`：按完整记录步长解析并校验原始触点输入
- `GestureTouchService`：隔离私有触控板框架的辅助进程
- `TrackpadProviders.swift`：辅助进程通信、崩溃恢复和公开 API 兼容后端
- `TouchServiceStreamDecoder.swift`：有界 JSON Lines 解析、分包处理和触点验证
- `PublicGestureAccumulator.swift`：公开事件累计，丢弃惯性滚动和取消的手势
- `GestureRecognizer.swift`：多指手势识别状态
- `HotkeyListener.swift`：完整 key-down/key-up Event Tap
- `GestureDaemon.swift`：输入模块生命周期与规则匹配
- `ActionExecutor.swift`：串行动作执行
- `KeyboardShortcut.swift`：快捷键预解析、别名归一化和事件修饰键匹配
- `GestureApp.swift`：AppKit 应用、窗口和菜单生命周期
- `SettingsViews.swift` / `RuleEditorViews.swift`：SwiftUI 设置内容与操作栏

## 限制

Apple 没有提供能够读取全部原始触点的公开 API，因此高级触控板模式使用系统私有的 `MultitouchSupport.framework`。该框架被隔离在 `GestureTouchService` 辅助进程内；连续异常数据会触发熔断，服务崩溃后主应用会重启一次并自动降级。公开 API 兼容模式不会加载该框架，但只能可靠识别两指滚动、捏合和系统 swipe。键盘模块使用公开的 CoreGraphics Event Tap。

高级模式的捏合/张开识别支持 4–5 指；两指捏合请切换兼容模式。兼容模式同时安装全局和本地监听，因为全局监听不会收到发给 Gesture 自身的事件，参见 [Apple 事件监听说明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)。兼容模式观察事件，无法阻止系统或原应用同时处理该手势。

辅助进程使用专用文件描述符发送 JSON Lines，并将框架自己的 stdout 诊断转到 stderr，避免正常设备输出触发错误降级。触点记录按完整的 96 字节步长读取并校验，不能按已用字段的末尾截断数组步长。

辅助进程必须在 5 秒内报告就绪；关闭时主界面不等待进程退出，不响应正常终止的进程会在 2 秒后被强制结束。每次启动使用独立会话，旧进程回调和旧的重启任务不能改变新引擎状态。多个触控设备的时间戳分别校验，每次手势只使用同一设备的触点。

Shell 和 AppleScript 动作以当前用户权限执行。只添加自己信任的脚本。

取消操作无法撤回已发送的按键、已打开的网页或应用，也不会管理脚本自行派生并脱离的后台进程。Fn 加方向键可能被 macOS 转换为 Home/End/Page Up/Page Down；快捷键按实际收到的键码记录和匹配。

## 开发验证

回归测试覆盖手势方向、距离、瞬时额外手指、部分抬起、捏合、快捷键阶段和连发、配置迁移与原文件保留、辅助进程启动超时和无响应关闭、消息分包与无效数据、动作顺序、取消及命令超时。测试使用临时配置和受控脚本，无需辅助功能授权或真实触控板输入。

```bash
make verify
# 检查跨线程捕获和共享状态，保留 Swift 5 语言模式兼容性
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

GitHub Actions 在 macOS 上执行相同验证。硬件验收仍需在解锁的 Mac 上检查实际 2–5 指输入、辅助功能授权后的按键发送、快捷键录制、规则优先级、设置窗口关闭/重开，以及 Dock/菜单栏隐藏后的应用唤回。

2026-10-01 本机验收记录见 [实测与验证报告](docs/verification-2026-10-01.md)，包含真实多指输入、捏合触点回放、快捷键录制、设置窗口与服务故障恢复。
