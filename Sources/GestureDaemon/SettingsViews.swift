import SwiftUI
import AppKit

private enum SidebarSelection: Hashable {
    case all
    case category(RuleCategory)
    case engine
    case recognition

    var title: String {
        switch self {
        case .all: return "全部规则"
        case .category(let category): return category.title
        case .engine: return "状态与权限"
        case .recognition: return "手势识别"
        }
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var viewState = SettingsViewState()

    private var section: SidebarSelection {
        get { viewState.section }
        nonmutating set { viewState.section = newValue }
    }
    private var selectedRuleID: UUID? {
        get { viewState.selectedRuleID }
        nonmutating set { viewState.selectedRuleID = newValue }
    }
    private var sectionBinding: Binding<SidebarSelection> { Binding(get: { section }, set: { section = $0 }) }
    private var selectedRuleBinding: Binding<UUID?> { Binding(get: { selectedRuleID }, set: { selectedRuleID = $0 }) }

    private var engine: GestureDaemon { model.engine }
    private var store: ConfigurationStore { model.store }

    var body: some View {
        Group {
            if isRulesSection {
                NavigationSplitView {
                    sidebar
                } content: {
                    ruleList
                } detail: {
                    detail
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        .toolbar { toolbar }
        .onAppear {
            if selectedRuleID == nil {
                DispatchQueue.main.async { selectedRuleID = filteredRules.first?.id }
            }
        }
        .onChange(of: viewState.section) { _ in
            selectedRuleID = filteredRules.first?.id
        }
        .alert("配置错误", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })) {
            Button("好") {}
        } message: { Text(store.lastError ?? "未知错误") }
    }

    private var sidebar: some View {
        List(selection: sectionBinding) {
            Section("规则") {
                Label("全部规则", systemImage: "list.bullet").tag(SidebarSelection.all)
                ForEach(RuleCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(SidebarSelection.category(category))
                }
            }
            Section("设置") {
                Label("状态与权限", systemImage: "checkmark.shield").tag(SidebarSelection.engine)
                Label("手势识别", systemImage: "slider.horizontal.3").tag(SidebarSelection.recognition)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }

    private var isRulesSection: Bool {
        if case .engine = section { return false }
        if case .recognition = section { return false }
        return true
    }

    private var filteredRules: [AutomationRule] {
        switch section {
        case .all: return store.configuration.rules
        case .category(let category): return store.configuration.rules.filter { $0.category == category }
        default: return []
        }
    }

    private var ruleList: some View {
        List(selection: selectedRuleBinding) {
            ForEach(filteredRules) { rule in
                RuleListRow(rule: binding(for: rule.id))
                    .tag(rule.id)
                    .contextMenu {
                        Button("复制") { duplicate(rule.id) }
                        Button("删除", role: .destructive) { delete(rule.id) }
                    }
            }
            .onDelete { indexes in
                for index in indexes.reversed() { delete(filteredRules[index].id) }
            }
        }
        .overlay {
            if filteredRules.isEmpty {
                EmptyStateView(title: "没有规则", systemImage: "wand.and.stars", detail: "点击工具栏的 ＋ 创建第一条规则")
            }
        }
        .navigationTitle(section.title)
        .navigationSplitViewColumnWidth(min: 260, ideal: 310)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .engine:
            EngineSettingsView(engine: engine, model: model)
        case .recognition:
            RecognitionSettingsView(settings: Binding(
                get: { store.configuration.settings },
                set: { store.configuration.settings = $0 }
            ))
        default:
            if let id = selectedRuleID, store.configuration.rules.contains(where: { $0.id == id }) {
                RuleEditorView(rule: binding(for: id))
            } else {
                EmptyStateView(title: "选择一条规则", systemImage: "sidebar.right", detail: "从中间列表选择要编辑的规则")
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if isRulesSection {
                Menu {
                    Button("触控板规则") { addRule(.trackpad) }
                    Button("键盘规则") { addRule(.keyboard) }
                } label: { Image(systemName: "plus") }
                .help("添加规则")
                Button { if let selectedRuleID { delete(selectedRuleID) } } label: { Image(systemName: "trash") }
                    .disabled(selectedRuleID == nil)
                    .help("删除所选规则")
            }
            Button("还原") { model.reloadAndApply() }
                .disabled(!store.hasUnsavedChanges)
                .help("放弃未保存的修改，恢复到已保存的配置")
            Button("保存并应用") { model.saveAndApply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .help("保存配置并让引擎立即生效 (⌘S)")
        }
    }

    private func binding(for id: UUID) -> Binding<AutomationRule> {
        Binding {
            store.configuration.rules.first(where: { $0.id == id }) ?? AutomationConfiguration.defaults.rules[0]
        } set: { value in
            guard let index = store.configuration.rules.firstIndex(where: { $0.id == id }) else { return }
            store.configuration.rules[index] = value
        }
    }

    private func addRule(_ category: RuleCategory) {
        let rule: AutomationRule
        switch category {
        case .trackpad:
            rule = AutomationRule(name: "新触控板规则", trigger: .trackpad(TrackpadTrigger()), actions: [.keyboard(["cmd", "w"])])
        case .keyboard:
            rule = AutomationRule(name: "新键盘规则", trigger: .keyboard(KeyboardTrigger()), actions: [.keyboard(["down"])])
        }
        store.configuration.rules.append(rule)
        selectedRuleID = rule.id
        section = .category(category)
    }

    private func delete(_ id: UUID) {
        store.configuration.rules.removeAll { $0.id == id }
        selectedRuleID = filteredRules.first?.id
    }

    private func duplicate(_ id: UUID) {
        guard var copy = store.configuration.rules.first(where: { $0.id == id }) else { return }
        copy.id = UUID(); copy.name += " 副本"
        store.configuration.rules.append(copy); selectedRuleID = copy.id
    }
}

private final class SettingsViewState: ObservableObject {
    @Published var section: SidebarSelection = .all
    @Published var selectedRuleID: UUID?
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct RuleListRow: View {
    @Binding var rule: AutomationRule

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rule.category.systemImage).foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        switch rule.trigger {
        case .trackpad(let t): return "\(t.fingers) 指 · \(t.direction.title)"
        case .keyboard(let t): return t.keys.map(KeyNames.display).joined(separator: " ")
        }
    }
}
