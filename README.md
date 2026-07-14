# Gesture

Gesture 是一个原生 macOS 触控板手势与组合键自动化工具。它以菜单栏应用运行，通过可视化界面创建“触发器 → App 范围 → 动作”规则，不再需要手动编辑配置文件。

## 功能

- 2–5 指上、下、左、右滑动，以及 4–5 指捏合/张开
- 全局组合键重映射，支持按下/松开触发和按键连发策略
- 规则可限定为所有 App、仅指定 App 或排除指定 App
- 一条规则可以依次执行多个动作
- 支持发送快捷键、打开网址、打开应用、Shell、AppleScript 和延时
- 菜单栏启停、运行状态、辅助功能权限诊断
- 私有触控板读取运行在独立辅助进程中，异常不会带崩主应用
- 辅助进程异常时自动重启一次，再自动切换到公开 API 兼容模式
- 可手动强制兼容模式，完全不加载私有触点框架
- 规则冲突、空动作和无效快捷键配置诊断
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
- `TouchListener.swift`：触控板原始触点输入
- `GestureTouchService`：隔离私有触控板框架的辅助进程
- `TrackpadProviders.swift`：辅助进程通信、崩溃恢复和公开 API 兼容后端
- `GestureRecognizer.swift`：多指手势识别状态
- `HotkeyListener.swift`：完整 key-down/key-up Event Tap
- `GestureDaemon.swift`：输入模块生命周期与规则匹配
- `ActionExecutor.swift`：串行动作执行
- `SettingsViews.swift` / `RuleEditorViews.swift`：原生设置界面

## 限制

Apple 没有提供能够读取全部原始触点的公开 API，因此高级触控板模式使用系统私有的 `MultitouchSupport.framework`。该框架被隔离在 `GestureTouchService` 辅助进程内；连续异常数据会触发熔断，服务崩溃后主应用会重启一次并自动降级。公开 API 兼容模式不会加载该框架，但只能可靠识别两指滚动、捏合和系统 swipe。键盘模块使用公开的 CoreGraphics Event Tap。

Shell 和 AppleScript 动作以当前用户权限执行。只添加自己信任的脚本。
