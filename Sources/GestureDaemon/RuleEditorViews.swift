import SwiftUI
import AppKit

struct RuleEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var rule: AutomationRule

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TextField("规则名称", text: $rule.name).textFieldStyle(.plain).font(.title2.bold())
                    Button {
                        model.engine.testActions(for: rule)
                    } label: {
                        Label("测试动作", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("按当前动作配置模拟执行一次")
                    Toggle("启用", isOn: $rule.isEnabled).toggleStyle(.switch)
                }
                Divider()
                GroupBox("触发器") { triggerEditor.padding(.top, 4) }
                GroupBox("适用范围") { scopeEditor.padding(.top, 4) }
                GroupBox("执行动作") { actionsEditor.padding(.top, 4) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle(rule.name)
    }

    @ViewBuilder private var triggerEditor: some View {
        switch rule.trigger {
        case .trackpad:
            let binding = Binding<TrackpadTrigger> {
                if case .trackpad(let value) = rule.trigger { return value }
                return TrackpadTrigger()
            } set: { rule.trigger = .trackpad($0) }
            TrackpadTriggerEditor(trigger: binding)
        case .keyboard:
            let binding = Binding<KeyboardTrigger> {
                if case .keyboard(let value) = rule.trigger { return value }
                return KeyboardTrigger()
            } set: { rule.trigger = .keyboard($0) }
            KeyboardTriggerEditor(trigger: binding)
        }
    }

    private var scopeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("生效范围", selection: $rule.applicationScope.mode) {
                ForEach(ApplicationScopeMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if rule.applicationScope.mode != .all {
                ForEach(rule.applicationScope.bundleIdentifiers, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(systemName: "app.dashed").foregroundStyle(.secondary)
                        Text(bundleID).textSelection(.enabled)
                        Spacer()
                        Button {
                            rule.applicationScope.bundleIdentifiers.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill").frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("移除此应用")
                    }
                }
                HStack(spacing: 8) {
                    Button("选择应用…") { chooseApplication() }.buttonStyle(.bordered)
                    Text("规则按 Bundle Identifier 匹配").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionsEditor: some View {
        VStack(spacing: 12) {
            ForEach($rule.actions) { $action in
                ActionEditor(action: $action) {
                    rule.actions.removeAll { $0.id == action.id }
                }
            }
            Menu {
                ForEach(ActionKind.allCases) { kind in
                    Button(kind.title) { rule.actions.append(AutomationAction(kind: kind)) }
                }
            } label: {
                Label("添加动作", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier,
               !rule.applicationScope.bundleIdentifiers.contains(bundleID) {
                rule.applicationScope.bundleIdentifiers.append(bundleID)
            }
        }
    }
}

private struct TrackpadTriggerEditor: View {
    @Binding var trigger: TrackpadTrigger

    var body: some View {
        Form {
            Picker("手指数", selection: $trigger.fingers) {
                ForEach(2...5, id: \.self) { Text("\($0) 指").tag($0) }
            }
            Picker("手势", selection: $trigger.direction) {
                ForEach(GestureDirection.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("触发距离") {
                HStack {
                    Slider(value: $trigger.minimumDistance, in: 0.02...0.5, step: 0.01)
                        .frame(width: 190)
                    Text(trigger.minimumDistance.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit().frame(width: 38)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyboardTriggerEditor: View {
    @Binding var trigger: KeyboardTrigger

    var body: some View {
        Form {
            LabeledContent("快捷键") { ShortcutCaptureButton(keys: $trigger.keys) }
            Picker("触发时机", selection: $trigger.phase) {
                ForEach(TriggerPhase.allCases) { Text($0.title).tag($0) }
            }
            Toggle("按住时允许连续触发", isOn: $trigger.allowRepeat)
        }
        .formStyle(.grouped)
    }
}

private struct ActionEditor: View {
    @Binding var action: AutomationAction
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 190)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").frame(width: 26, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("删除此动作")
            }
            editor
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var editor: some View {
        switch action.kind {
        case .keyboardShortcut:
            ShortcutCaptureButton(keys: $action.keys)
        case .openURL:
            TextField("https://example.com", text: $action.value)
        case .launchApplication:
            TextField("Bundle ID 或 /Applications/App.app", text: $action.value)
        case .shellScript:
            TextEditor(text: $action.value).font(.system(.body, design: .monospaced)).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
        case .appleScript:
            TextEditor(text: $action.value).font(.system(.body, design: .monospaced)).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
        case .delay:
            HStack {
                TextField("毫秒", value: $action.delayMilliseconds, format: .number).frame(width: 100)
                Text("毫秒").foregroundStyle(.secondary)
            }
        }
    }
}

struct ShortcutCaptureButton: View {
    @Binding var keys: [String]
    @ObservedObject private var recorder = ShortcutRecorderState()

    var body: some View {
        Button {
            startRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recorder.isRecording ? "record.circle" : "keyboard")
                if recorder.isRecording { Text("请按快捷键…").foregroundStyle(.secondary) }
                else { Text(keys.isEmpty ? "点击录制" : keys.map(KeyNames.display).joined(separator: " ")).monospaced() }
            }
            .frame(minWidth: 150)
        }
        .buttonStyle(.bordered)
        .help("点击后直接按下想要录制的组合键")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        recorder.isRecording = true
        recorder.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var captured: [String] = []
            if event.modifierFlags.contains(.control) { captured.append("ctrl") }
            if event.modifierFlags.contains(.option) { captured.append("option") }
            if event.modifierFlags.contains(.shift) { captured.append("shift") }
            if event.modifierFlags.contains(.command) { captured.append("cmd") }
            if event.modifierFlags.contains(.function) { captured.append("fn") }
            if let name = KeyNames.name(for: CGKeyCode(event.keyCode)) { captured.append(name) }
            if !captured.isEmpty { keys = captured }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = recorder.monitor { NSEvent.removeMonitor(monitor) }
        recorder.monitor = nil; recorder.isRecording = false
    }
}

private final class ShortcutRecorderState: ObservableObject {
    @Published var isRecording = false
    var monitor: Any?
}

enum KeyNames {
    static func display(_ key: String) -> String {
        switch key.lowercased() {
        case "cmd", "command": return "⌘"
        case "option", "opt", "alt": return "⌥"
        case "shift": return "⇧"
        case "ctrl", "control": return "⌃"
        case "fn", "function": return "fn"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "return", "enter": return "↩"
        case "delete", "backspace": return "⌫"
        case "escape", "esc": return "⎋"
        case "space": return "Space"
        default: return key.uppercased()
        }
    }

    static func name(for code: CGKeyCode) -> String? {
        let candidates = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
            + Array(0...9).map(String.init)
            + ["space", "return", "tab", "delete", "escape", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "left", "right", "up", "down", "home", "end", "pageup", "pagedown", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
        return candidates.first { KeySimulator.keyCodeFor(name: $0) == code }
    }
}

struct EngineSettingsView: View {
    @ObservedObject var engine: GestureDaemon
    let model: AppModel

    var body: some View {
        Form {
            Section("启动与外观") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { model.store.configuration.settings.launchAtLogin },
                    set: { model.store.configuration.settings.launchAtLogin = $0 }
                ))
                Toggle("隐藏 Dock 图标", isOn: Binding(
                    get: { model.store.configuration.settings.hideDockIcon },
                    set: { model.setDockIconHidden($0) }
                ))
                Toggle("隐藏菜单栏图标", isOn: Binding(
                    get: { model.store.configuration.settings.hideMenuBarIcon },
                    set: { model.setMenuBarIconHidden($0) }
                ))
                Text("外观选项会自动保存并立即生效。若两个图标都隐藏，可从“应用程序”文件夹再次打开 Gesture 唤回设置窗口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("运行状态") {
                StatusRow(title: "自动化引擎", available: engine.isRunning, detail: engine.isRunning ? "运行中" : "已停止")
                StatusRow(title: "触控板监听", available: engine.trackpadAvailable, detail: engine.trackpadMode)
                StatusRow(title: "键盘监听", available: engine.keyboardAvailable, detail: engine.keyboardAvailable ? "已连接" : "不可用或没有启用规则")
                LabeledContent("最近触发", value: engine.lastEvent)
                LabeledContent("最近触点", value: engine.lastTouchObservation)
                LabeledContent("最近识别", value: engine.lastGestureObservation)
                HStack(spacing: 8) {
                    Button(engine.isRunning ? "重新启动引擎" : "启动引擎") { engine.start(configuration: model.store.configuration) }
                        .buttonStyle(.borderedProminent)
                    if engine.isRunning {
                        Button("停止") { engine.stop() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            Section("系统权限") {
                StatusRow(title: "辅助功能", available: engine.accessibilityGranted, detail: engine.accessibilityGranted ? "已授权" : "需要授权")
                if !engine.accessibilityGranted {
                    HStack(spacing: 8) {
                        Button("请求辅助功能权限…") { engine.requestAccessibilityPermission() }
                            .buttonStyle(.borderedProminent)
                        Button("打开辅助功能设置") { engine.openAccessibilitySettings() }
                            .buttonStyle(.bordered)
                    }
                }
                Text("监听全局快捷键和模拟按键需要辅助功能权限。授权后请重新启动引擎。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("高级模式支持精确 2–5 指手势；兼容模式使用公开系统事件，只能可靠提供两指滚动、捏合和系统 swipe。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !engine.errorMessages.isEmpty {
                Section("诊断") { ForEach(engine.errorMessages, id: \.self) { Text($0).foregroundStyle(.red) } }
            }
            if !engine.configurationWarnings.isEmpty {
                Section("配置提醒") {
                    ForEach(engine.configurationWarnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            Section("配置文件") {
                Text(model.store.url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }
                        .buttonStyle(.bordered)
                    Button("打开诊断日志") { NSWorkspace.shared.open(DiagnosticLog.url) }
                        .buttonStyle(.bordered)
                }
            }
            Section("触控板后端") {
                Toggle("强制使用公开 API 兼容模式", isOn: Binding(
                    get: { model.store.configuration.settings.useCompatibilityTrackpadMode },
                    set: { model.store.configuration.settings.useCompatibilityTrackpadMode = $0 }
                ))
                Text("兼容模式不会加载私有触点框架，但只能识别两指滚动、捏合和系统 swipe。修改后点击“保存并应用”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(10).navigationTitle("状态与权限")
    }
}

private struct StatusRow: View {
    let title: String
    let available: Bool
    let detail: String
    var body: some View {
        LabeledContent(title) {
            Label(detail, systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(available ? .green : .orange)
        }
    }
}

struct RecognitionSettingsView: View {
    @Binding var settings: EngineSettings

    var body: some View {
        Form {
            Section("触发") {
                valueSlider("实时触发距离", value: $settings.liveTriggerDistance, range: 0.01...0.3)
                valueSlider("最小滑动距离", value: $settings.minimumSwipeDistance, range: 0...0.1)
                LabeledContent("动作防抖") {
                    TextField("毫秒", value: $settings.debounceMilliseconds, format: .number).frame(width: 90)
                }
            }
            Section("方向判断") {
                valueSlider("对角线拒绝比例", value: $settings.diagonalRejectRatio, range: 0.5...1)
                valueSlider("向下偏移修正", value: $settings.downBiasRatio, range: 0...1)
                valueSlider("向下最小分量", value: $settings.downBiasMinimumY, range: 0...0.3)
            }
            Section("捏合与张开") {
                valueSlider("变化阈值", value: $settings.spreadThreshold, range: 0...0.2)
                valueSlider("位移优先比例", value: $settings.spreadToDistanceRatio, range: 0...5)
            }
            Section {
                Button("恢复默认识别参数") {
                    let defaults = EngineSettings()
                    settings.debounceMilliseconds = defaults.debounceMilliseconds
                    settings.diagonalRejectRatio = defaults.diagonalRejectRatio
                    settings.downBiasRatio = defaults.downBiasRatio
                    settings.spreadThreshold = defaults.spreadThreshold
                    settings.minimumSwipeDistance = defaults.minimumSwipeDistance
                    settings.downBiasMinimumY = defaults.downBiasMinimumY
                    settings.spreadToDistanceRatio = defaults.spreadToDistanceRatio
                    settings.liveTriggerDistance = defaults.liveTriggerDistance
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped).padding(10).navigationTitle("手势识别")
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 190)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 38)
            }
        }
    }
}
