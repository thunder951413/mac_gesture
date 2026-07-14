import SwiftUI
import AppKit
import Combine

@MainActor
private func activateGestureApp() {
    if #available(macOS 14.0, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
}

@main
struct GestureApp: App {
    @NSApplicationDelegateAdaptor(GestureAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Gesture 设置…") { model.showSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class GestureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .gestureShowSettings, object: nil)
        return true
    }
}

private extension Notification.Name {
    static let gestureShowSettings = Notification.Name("com.gesture.show-settings")
}

@MainActor
final class AppModel: ObservableObject {
    let store: ConfigurationStore
    let engine = GestureDaemon()
    private var subscriptions = Set<AnyCancellable>()
    private lazy var statusItemController = StatusItemController(model: self)
    private lazy var settingsWindowController = SettingsWindowController(model: self)

    init() {
        store = ConfigurationStore()
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.statusItemController.refresh() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                self?.applyAppearanceSettings()
                self?.showSettingsWindow()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .gestureShowSettings)
            .sink { [weak self] _ in self?.showSettingsWindow() }
            .store(in: &subscriptions)
        if !FileManager.default.fileExists(atPath: store.url.path) { store.saveReportingError() }
        engine.start(configuration: store.configuration)
        DispatchQueue.main.async { [weak self] in
            self?.applyAppearanceSettings()
            self?.showSettingsWindow()
        }
        if !engine.accessibilityGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.engine.requestAccessibilityPermission()
            }
        }
    }

    func saveAndApply() {
        store.saveReportingError()
        guard store.lastError == nil else { return }
        do { try LaunchAtLogin.apply(enabled: store.configuration.settings.launchAtLogin) }
        catch { fputs("[Gesture] 登录启动设置失败：\(error.localizedDescription)\n", stderr) }
        applyAppearanceSettings()
        engine.apply(configuration: store.configuration)
    }

    func reloadAndApply() {
        store.reload()
        guard store.lastError == nil else { return }
        applyAppearanceSettings()
        engine.apply(configuration: store.configuration)
    }

    func setDockIconHidden(_ hidden: Bool) {
        store.configuration.settings.hideDockIcon = hidden
        saveAppearanceAndApply()
    }

    func setMenuBarIconHidden(_ hidden: Bool) {
        store.configuration.settings.hideMenuBarIcon = hidden
        saveAppearanceAndApply()
    }

    func showSettingsWindow() {
        settingsWindowController.show()
    }

    private func saveAppearanceAndApply() {
        store.saveReportingError()
        guard store.lastError == nil else { return }
        applyAppearanceSettings()
    }

    private func applyAppearanceSettings() {
        let settings = store.configuration.settings
        statusItemController.setVisible(!settings.hideMenuBarIcon)
        let policy: NSApplication.ActivationPolicy = settings.hideDockIcon ? .accessory : .regular
        let visibleWindows = NSApp.windows.filter(\.isVisible)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        // 切换 regular/accessory 会让 SwiftUI 窗口短暂失去前台身份。
        // 下一轮 RunLoop 恢复原有可见窗口，避免用户感觉设置页“跳走”。
        DispatchQueue.main.async {
            visibleWindows.forEach { $0.orderFrontRegardless() }
            visibleWindows.first(where: { $0.canBecomeKey })?.makeKey()
            activateGestureApp()
        }
        DiagnosticLog.shared.write("[Appearance] Dock：\(settings.hideDockIcon ? "隐藏" : "显示")；菜单栏：\(settings.hideMenuBarIcon ? "隐藏" : "显示")；policy=\(policy.rawValue)")
    }
}

@MainActor
private final class StatusItemController: NSObject, NSMenuDelegate {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
    }

    func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.menu = menu
            statusItem = item
            refresh()
        } else if !visible, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func refresh() {
        guard let model, let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: model.engine.isRunning ? "hand.draw.fill" : "hand.draw", accessibilityDescription: "Gesture")
        button.toolTip = model.engine.isRunning ? "Gesture — 引擎运行中" : "Gesture — 引擎已停止"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        menu.removeAllItems()
        let status = NSMenuItem(title: model.engine.isRunning ? "引擎运行中" : "引擎已停止", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let event = NSMenuItem(title: model.engine.lastEvent, action: nil, keyEquivalent: "")
        event.isEnabled = false
        menu.addItem(event)
        menu.addItem(.separator())
        menu.addItem(item("打开设置…", action: #selector(openSettings)))
        menu.addItem(item(model.engine.isRunning ? "停止引擎" : "启动引擎", action: #selector(toggleEngine)))
        menu.addItem(.separator())
        menu.addItem(item("退出 Gesture", action: #selector(terminate), key: "q"))
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings() { model?.showSettingsWindow() }

    @objc private func toggleEngine() {
        guard let model else { return }
        if model.engine.isRunning { model.engine.stop() }
        else { model.engine.start(configuration: model.store.configuration) }
    }

    @objc private func terminate() { NSApp.terminate(nil) }
}

@MainActor
private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let rootView = SettingsRootView()
            .environmentObject(model)
            .frame(minWidth: 900, minHeight: 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gesture 设置"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: rootView)
        window.setAccessibilityRole(.window)
        window.setAccessibilitySubrole(.standardWindow)
        window.setAccessibilityLabel("Gesture 设置")
        window.setFrameAutosaveName("GestureSettingsWindowV3")
        if window.frame.width < 900 || window.frame.height < 600 {
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.center()
        }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        showWindow(nil)
        window.orderFrontRegardless()
        window.makeKey()
        activateGestureApp()
        DiagnosticLog.shared.write("[Appearance] 设置窗口已显示：visible=\(window.isVisible)")
    }

}
