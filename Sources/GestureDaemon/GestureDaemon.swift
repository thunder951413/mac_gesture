import Foundation
import AppKit
// AX 的选项常量在 C 头文件中以可变全局声明；此处只读取系统常量。
@preconcurrency import ApplicationServices
import GestureTouchCore

@MainActor
final class GestureDaemon: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var trackpadAvailable = false
    @Published private(set) var trackpadMode = "未启动"
    @Published private(set) var keyboardAvailable = false
    @Published private(set) var lastEvent = "尚未触发规则"
    @Published private(set) var lastTouchObservation = "尚未收到触点"
    @Published private(set) var lastGestureObservation = "尚未识别手势"
    @Published private(set) var errorMessages: [String] = []
    @Published private(set) var configurationWarnings: [String] = []

    private var configuration = AutomationConfiguration.defaults
    private var trackpadRules: [AutomationRule] = []
    private var recognizer: GestureRecognizer?
    private var touchService: TouchServiceProvider?
    private var publicGestureProvider: PublicGestureProvider?
    private var hotkeyListener: HotkeyListener?
    private var executor: ActionExecutor?
    private var testExecutor: ActionExecutor?
    private var sessionID = UUID()
    private var restartWorkItem: DispatchWorkItem?
    private var permissionPrompted = false
    private var isRecordingShortcut = false
    private var lastTriggerTimes: [UUID: TimeInterval] = [:]
    private var touchRestartAttempts = 0
    private var lastTouchObservationTime: TimeInterval = 0
    private var lastGestureObservationTime: TimeInterval = 0

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func start(configuration: AutomationConfiguration) {
        stop()
        self.configuration = configuration
        self.configuration.settings = configuration.settings.normalized
        isEnabled = true
        errorMessages = []
        configurationWarnings = ConfigurationValidator.warnings(for: configuration)
        trackpadRules = configuration.rules.filter { $0.category == .trackpad && ConfigurationValidator.isExecutable($0) }
        DiagnosticLog.shared.write("[Engine] 应用配置：\(configuration.rules.count) 条规则")
        DiagnosticLog.shared.write("[Permission] 辅助功能：\(accessibilityGranted ? "已授权" : "未授权")")
        DiagnosticLog.shared.write("[Permission] 事件监听：\(CGPreflightListenEventAccess() ? "允许" : "拒绝")；事件发送：\(CGPreflightPostEventAccess() ? "允许" : "拒绝")")
        executor = makeExecutor()
        touchRestartAttempts = 0
        configureTrackpad()
        configureKeyboard()
        updateRunningState()
    }

    func apply(configuration: AutomationConfiguration) {
        start(configuration: configuration)
    }

    func testActions(for rule: AutomationRule) {
        DiagnosticLog.shared.write("[Rule] 手动测试：\(rule.name)")
        if executor == nil && testExecutor == nil { testExecutor = makeExecutor() }
        _ = execute(rule, manually: true)
    }

    func setShortcutRecording(_ recording: Bool) { isRecordingShortcut = recording }

    func stop() {
        sessionID = UUID()
        restartWorkItem?.cancel()
        restartWorkItem = nil
        hotkeyListener?.stop()
        hotkeyListener = nil
        touchService?.stop()
        touchService = nil
        publicGestureProvider?.stop()
        publicGestureProvider = nil
        recognizer = nil
        executor?.cancel()
        executor = nil
        testExecutor?.cancel()
        testExecutor = nil
        lastTriggerTimes.removeAll()
        isRunning = false
        isEnabled = false
        trackpadAvailable = false
        trackpadMode = "未启动"
        keyboardAvailable = false
    }

    func requestAccessibilityPermission() {
        DiagnosticLog.shared.write("[Permission] 请求辅助功能授权")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func configureTrackpad() {
        guard !trackpadRules.isEmpty else { return }
        let recognizer = GestureRecognizer()
        let s = configuration.settings
        recognizer.tuning = GestureTuning(
            diagonalRejectRatio: CGFloat(s.diagonalRejectRatio), downBiasRatio: CGFloat(s.downBiasRatio),
            spreadThreshold: CGFloat(s.spreadThreshold), minSwipeDistance: CGFloat(s.minimumSwipeDistance),
            downBiasMinAbsDy: CGFloat(s.downBiasMinimumY), spreadToDistanceRatio: CGFloat(s.spreadToDistanceRatio),
            liveTriggerDistance: CGFloat(s.liveTriggerDistance), logLevel: s.logLevel
        )
        recognizer.onGesture = { [weak self] event in
            guard let self else { return false }
            if Thread.isMainThread { return self.handleGesture(event) }
            return DispatchQueue.main.sync { self.handleGesture(event) }
        }
        recognizer.onTrace = { [weak self] trace in
            guard let self else { return }
            GestureTraceLog.shared.write(trace)
            if trace.decision == .rejectedIncoherentSwipe {
                let observation = "已忽略 \(trace.fingers) 指滑动：触点未共同移动"
                self.lastGestureObservation = observation
                DiagnosticLog.shared.write("[GestureGuard] \(observation)")
            } else if trace.decision == .ignoredLateContact {
                self.lastGestureObservation = "已保留两指滑动：新增触点未计入手指数"
                DiagnosticLog.shared.write("[GestureGuard] \(self.lastGestureObservation)")
            }
        }
        self.recognizer = recognizer
        if configuration.settings.useCompatibilityTrackpadMode {
            startPublicFallback(reason: "已手动选择兼容模式")
            return
        }
        launchAdvancedTouchService()
    }

    private func configureKeyboard() {
        let keyboardRules = configuration.rules.filter { ConfigurationValidator.isExecutable($0) && $0.category == .keyboard }
        guard !keyboardRules.isEmpty else { return }
        let session = sessionID
        let listener = HotkeyListener(rules: keyboardRules, logDebug: configuration.settings.logLevel == "debug", shouldHandleEvents: { [weak self] in
            self?.isRecordingShortcut == false
        }) { [weak self] rule in
            DispatchQueue.main.async {
                guard let self, self.sessionID == session, self.isEnabled else { return }
                _ = self.execute(rule)
            }
        }
        hotkeyListener = listener
        keyboardAvailable = listener.start()
        if keyboardAvailable {
            DiagnosticLog.shared.write("[Keyboard] Event Tap 已启动：\(keyboardRules.count) 条规则")
        } else {
            errorMessages.append("键盘：无法创建 Event Tap，请检查辅助功能权限")
            DiagnosticLog.shared.write("[Keyboard] Event Tap 创建失败")
        }
        updateRunningState()
    }

    private func handleTouchServiceState(_ state: TrackpadProviderState) {
        switch state {
        case .starting:
            trackpadMode = "正在启动高级模式…"
            DiagnosticLog.shared.write("[Trackpad] 正在启动高级模式")
        case .advanced:
            trackpadAvailable = true
            trackpadMode = "高级模式（原始多指触点）"
            DiagnosticLog.shared.write("[Trackpad] 高级模式就绪")
            updateRunningState()
        case .compatible(let reason):
            trackpadAvailable = true
            trackpadMode = "兼容模式（公开事件）"
            if !reason.isEmpty { appendErrorOnce("触控板已降级：\(reason)") }
            DiagnosticLog.shared.write("[Trackpad] 进入兼容模式：\(reason)")
            updateRunningState()
        case .failed(let reason):
            trackpadAvailable = false
            updateRunningState()
            recognizer?.reset()
            if touchRestartAttempts < 1 {
                touchRestartAttempts += 1
                appendErrorOnce("高级触控板服务异常，正在自动重启一次：\(reason)")
                DiagnosticLog.shared.write("[Trackpad] 服务异常并重启：\(reason)")
                touchService?.stop()
                touchService = nil
                let session = sessionID
                let restart = DispatchWorkItem { [weak self] in
                    guard let self, self.sessionID == session, self.isEnabled else { return }
                    self.launchAdvancedTouchService()
                }
                restartWorkItem = restart
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restart)
            } else {
                startPublicFallback(reason: reason)
            }
        }
    }

    private func launchAdvancedTouchService() {
        guard let recognizer else { return }
        let service = TouchServiceProvider()
        service.onFrame = { [weak self, weak recognizer] touches, timestamp in
            recognizer?.processTouches(touches, timestamp: timestamp)
            self?.observeTouches(touches, acceptedFingers: recognizer?.acceptedTouchCount ?? 0,
                                 rejectedPalms: recognizer?.rejectedPalmCount ?? 0)
        }
        service.onStateChange = { [weak self] state in self?.handleTouchServiceState(state) }
        touchService = service
        do { try service.start() }
        catch {
            if touchRestartAttempts < 1 {
                handleTouchServiceState(.failed(error.localizedDescription))
            } else {
                startPublicFallback(reason: error.localizedDescription)
            }
        }
    }

    private func startPublicFallback(reason: String) {
        touchService?.stop()
        touchService = nil
        let provider = PublicGestureProvider()
        provider.onGesture = { [weak self] event in _ = self?.handleGesture(event) }
        publicGestureProvider = provider
        if provider.start() {
            handleTouchServiceState(.compatible(reason))
        } else {
            trackpadAvailable = false
            trackpadMode = "不可用"
            appendErrorOnce("触控板：\(reason)；公开事件兼容模式也无法启动")
            updateRunningState()
        }
    }

    private func appendErrorOnce(_ message: String) {
        if !errorMessages.contains(message) { errorMessages.append(message) }
    }

    private func updateRunningState() {
        isRunning = trackpadAvailable || keyboardAvailable
    }

    private func handleGesture(_ event: GestureEvent) -> Bool {
        guard isEnabled else { return false }
        let observation = "\(event.fingers) 指 · \(event.direction.title) · 距离 \(String(format: "%.3f", event.distance))"
        let bundleIdentifier = frontmostBundleIdentifier
        let matchedRule = trackpadRules.first(where: { rule in
            guard case .trackpad(let trigger) = rule.trigger else { return false }
            guard trigger.fingers == event.fingers, trigger.direction == event.direction else { return false }
            let distance = trigger.direction == .down ? max(0, -event.dy) : event.distance
            return distance >= CGFloat(trigger.minimumDistance) && rule.applicationScope.matches(bundleIdentifier: bundleIdentifier)
        })
        // live-trigger 未命中时识别器每帧重试，观察信息与日志按时间窗节流，
        // 避免滑动期间高频刷新 UI 与刷写诊断日志。规则匹配与执行不受影响。
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastGestureObservationTime >= 0.2 {
            lastGestureObservationTime = now
            lastGestureObservation = observation
            DiagnosticLog.shared.write("[Gesture] \(observation)" + (matchedRule == nil ? "；没有匹配的启用规则" : ""))
        }
        guard let matchedRule else { return false }
        return execute(matchedRule, gesture: event)
    }

    private func execute(_ rule: AutomationRule, manually: Bool = false, gesture: GestureEvent? = nil) -> Bool {
        guard manually || (isEnabled && rule.applicationScope.matches(bundleIdentifier: frontmostBundleIdentifier)) else { return false }
        guard !rule.actions.isEmpty, rule.actions.allSatisfy(ConfigurationValidator.isValid) else {
            let message = "规则“\(rule.name)”的动作为空或无效，请先修正配置"
            lastEvent = message
            appendErrorOnce(message)
            return true
        }
        if rule.actions.contains(where: { $0.kind == .keyboardShortcut }) && !accessibilityGranted {
            let message = "规则“\(rule.name)”已匹配，但辅助功能未授权，无法发送按键"
            lastEvent = message
            appendErrorOnce(message)
            DiagnosticLog.shared.write("[Permission] \(message)")
            if !permissionPrompted { permissionPrompted = true; requestAccessibilityPermission() }
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        let debounce = TimeInterval(max(0, configuration.settings.debounceMilliseconds)) / 1000
        if !manually, let last = lastTriggerTimes[rule.id], now - last < debounce { return true }
        guard (manually ? (executor ?? testExecutor) : executor)?.execute(rule.actions, ruleName: rule.name) == true else {
            appendErrorOnce("动作队列已满，已跳过“\(rule.name)”")
            return true
        }
        if !manually { lastTriggerTimes[rule.id] = now }
        if let gesture {
            recognizer?.recordTriggeredGesture(gesture)
            DiagnosticLog.shared.write("[GestureMatch] \(gesture.fingers) 指 · \(gesture.direction.title) · 距离 \(String(format: "%.3f", gesture.distance)) · dx=\(String(format: "%.3f", gesture.dx)) dy=\(String(format: "%.3f", gesture.dy))")
        }
        lastEvent = "\(rule.name) · \(Date().formatted(date: .omitted, time: .standard))"
        DiagnosticLog.shared.write("[Rule] 触发：\(rule.name)")
        return true
    }

    private func makeExecutor() -> ActionExecutor {
        let executor = ActionExecutor(debounceMilliseconds: configuration.settings.debounceMilliseconds)
        let session = sessionID
        executor.onCompletion = { [weak self] name, failure in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionID == session, let failure else { return }
                let message = "规则“\(name)”执行失败：\(failure)"
                self.lastEvent = message
                self.appendErrorOnce(message)
            }
        }
        return executor
    }

    private var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func observeTouches(_ touches: [ActiveTouch], acceptedFingers: Int, rejectedPalms: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard touches.isEmpty || now - lastTouchObservationTime >= 0.1 else { return }
        lastTouchObservationTime = now
        if touches.isEmpty {
            lastTouchObservation = "触点已全部抬起"
        } else {
            lastTouchObservation = "收到 \(touches.count) 个触点，手势使用 \(acceptedFingers) 指"
            if rejectedPalms > 0 { lastTouchObservation += "，已过滤 \(rejectedPalms) 个掌缘触点" }
        }
    }
}
