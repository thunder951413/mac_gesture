import SwiftUI
import AppKit
import Combine

@MainActor
private func activateGestureApp() {
    if #available(macOS 14.0, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
}

// 窗口和菜单栏由 AppKit 管理，SwiftUI 只负责设置内容。使用空 Settings
// scene 会额外生成空白窗口，并且不会给独立 NSHostingController 安装工具栏。
@main
@MainActor
enum GestureApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = GestureAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class GestureAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        model = AppModel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .gestureShowSettings, object: nil)
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Gesture")
        for (title, selector, key) in [
            ("Gesture 设置…", #selector(showSettings), ","),
            ("保存并应用", #selector(saveAndApply), "s")
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            applicationMenu.addItem(item)
        }
        applicationMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏 Gesture", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        applicationMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        applicationMenu.addItem(hideOthers)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Gesture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("撤销", NSSelectorFromString("undo:"), "z"),
            ("重做", NSSelectorFromString("redo:"), "Z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key.lowercased())
            if key == "Z" { item.keyEquivalentModifierMask = [.command, .shift] }
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettings() { model?.showSettingsWindow() }
    @objc private func saveAndApply() { model?.saveAndApply() }
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
    private lazy var settingsWindowCoordinator = SettingsWindowCoordinator(model: self)
    private var hasPresentedInitialWindow = false

    init() {
        store = ConfigurationStore()
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        engine.$isRunning.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.statusItemController.refresh() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                self?.applyAppearanceSettings()
                self?.showInitialSettingsWindowIfNeeded()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .gestureShowSettings)
            .sink { [weak self] _ in self?.showSettingsWindow() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.engine.stop() }
            .store(in: &subscriptions)
        if !FileManager.default.fileExists(atPath: store.url.path) { store.saveReportingError() }
        engine.start(configuration: store.configuration)
        DispatchQueue.main.async { [weak self] in
            self?.applyAppearanceSettings()
            self?.showInitialSettingsWindowIfNeeded()
        }
    }

    func saveAndApply() {
        store.saveReportingError()
        guard store.lastError == nil else { return }
        do { try LaunchAtLogin.apply(enabled: store.configuration.settings.launchAtLogin) }
        catch { store.reportError(error) }
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
        saveAppearanceAndApply(\.hideDockIcon, value: hidden)
    }

    func setMenuBarIconHidden(_ hidden: Bool) {
        saveAppearanceAndApply(\.hideMenuBarIcon, value: hidden)
    }

    func showSettingsWindow() {
        settingsWindowCoordinator.show()
    }

    private func saveAppearanceAndApply(_ keyPath: WritableKeyPath<EngineSettings, Bool>, value: Bool) {
        do { try store.saveAppearance(keyPath, value: value) }
        catch { store.reportError(error); return }
        applyAppearanceSettings()
    }

    private func showInitialSettingsWindowIfNeeded() {
        guard !hasPresentedInitialWindow else { return }
        hasPresentedInitialWindow = true
        showSettingsWindow()
    }

    private func applyAppearanceSettings() {
        let settings = store.configuration.settings
        statusItemController.setVisible(!settings.hideMenuBarIcon)
        let policy: NSApplication.ActivationPolicy = settings.hideDockIcon ? .accessory : .regular
        let policyChanged = NSApp.activationPolicy() != policy
        let visibleWindows = NSApp.windows.filter(\.isVisible)
        if policyChanged { NSApp.setActivationPolicy(policy) }
        // 切换 regular/accessory 会让 SwiftUI 窗口短暂失去前台身份。
        // 下一轮 RunLoop 恢复原有可见窗口，避免用户感觉设置页“跳走”。
        if policyChanged && !visibleWindows.isEmpty { DispatchQueue.main.async {
            activateGestureApp()
            visibleWindows.forEach { $0.orderFront(nil) }
            visibleWindows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
        } }
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
        // 引擎可能仍在运行但触控板已降级，从菜单直接暴露原因，
        // 不必打开设置页的“诊断”区才能发现。
        for message in model.engine.errorMessages.prefix(2) {
            let diagnostic = NSMenuItem(title: Self.truncated(message), action: nil, keyEquivalent: "")
            diagnostic.isEnabled = false
            menu.addItem(diagnostic)
        }
        menu.addItem(.separator())
        menu.addItem(item("打开设置…", action: #selector(openSettings)))
        menu.addItem(item(model.engine.isEnabled ? "停止引擎" : "启动引擎", action: #selector(toggleEngine)))
        menu.addItem(.separator())
        menu.addItem(item("退出 Gesture", action: #selector(terminate), key: "q"))
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private static func truncated(_ message: String) -> String {
        message.count <= 100 ? message : "\(message.prefix(100))…"
    }

    @objc private func openSettings() { model?.showSettingsWindow() }

    @objc private func toggleEngine() {
        guard let model else { return }
        if model.engine.isEnabled { model.engine.stop() }
        else { model.engine.start(configuration: model.store.configuration) }
    }

    @objc private func terminate() { NSApp.terminate(nil) }
}

@MainActor
private final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        guard let window = window ?? makeWindow() else { return }
        self.window = window
        if window.contentViewController == nil {
            installContent(in: window)
        }
        activateGestureApp()
        window.makeKeyAndOrderFront(nil)
        DiagnosticLog.shared.write("[Appearance] 设置窗口已显示：visible=\(window.isVisible)")
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        // NSHostingController 会安装大量跟踪区域。关闭后立刻拆掉视图树，
        // 避免不可见窗口继续参与 AppKit 的鼠标/光标跟踪循环。
        closingWindow.contentViewController = nil
        DiagnosticLog.shared.write("[Appearance] 设置窗口已关闭，内容视图已释放")
    }

    private func makeWindow() -> NSWindow? {
        guard model != nil else { return nil }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gesture 设置"
        window.contentMinSize = NSSize(width: 900, height: 600)
        // 菜单栏应用需要在设置页关闭后继续运行。保留轻量窗口外壳，
        // 但 windowWillClose 会释放真正昂贵的 SwiftUI 内容树。
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        installContent(in: window)
        window.setFrameAutosaveName("GestureSettingsWindowV3")
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.center()
        }
        window.delegate = self
        return window
    }

    private func installContent(in window: NSWindow) {
        guard let model else { return }
        let rootView = SettingsRootView()
            .environmentObject(model)
            .frame(minWidth: 900, minHeight: 600)
        window.contentViewController = NSHostingController(rootView: rootView)
    }
}
