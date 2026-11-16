import SwiftUI

/// 主工作区激活时注入的 Query 菜单动作。
///
/// 编辑器上下文（已连接且未打开表浏览 / Redis 键面板）启用执行、格式化与标签
/// 管理；网格上下文（打开了表浏览）启用提交变更与筛选。两上下文互斥，避免与
/// 网格自带的 ⌘S 保存改动、⌘⇧N 新行冲突。菜单快捷键与工具条按钮上的同名
/// 快捷键共存：视图在响应链中时按钮优先，菜单提供全局入口与可发现性。
public struct QueryMenuActions {
    public let run: () -> Void
    public let runAll: () -> Void
    public let stop: () -> Void
    public let format: () -> Void
    public let explain: () -> Void
    public let showHistory: () -> Void
    public let newTab: () -> Void
    public let closeTab: () -> Void
    public let reopenClosedTab: () -> Void
    public let nextTab: () -> Void
    public let previousTab: () -> Void
    public let selectTab: (Int) -> Void
    public let commitChanges: () -> Void
    public let toggleFilter: () -> Void

    public let canRun: Bool
    public let canStop: Bool
    public let canFormat: Bool
    public let canExplain: Bool
    public let canManageTabs: Bool
    public let canReopenClosedTab: Bool
    public let tabCount: Int
    public let canCommitChanges: Bool
    public let canToggleFilter: Bool

    public init(
        run: @escaping () -> Void,
        runAll: @escaping () -> Void,
        stop: @escaping () -> Void,
        format: @escaping () -> Void,
        explain: @escaping () -> Void,
        showHistory: @escaping () -> Void,
        newTab: @escaping () -> Void,
        closeTab: @escaping () -> Void,
        reopenClosedTab: @escaping () -> Void,
        nextTab: @escaping () -> Void,
        previousTab: @escaping () -> Void,
        selectTab: @escaping (Int) -> Void,
        commitChanges: @escaping () -> Void,
        toggleFilter: @escaping () -> Void,
        canRun: Bool,
        canStop: Bool,
        canFormat: Bool,
        canExplain: Bool,
        canManageTabs: Bool,
        canReopenClosedTab: Bool,
        tabCount: Int,
        canCommitChanges: Bool,
        canToggleFilter: Bool
    ) {
        self.run = run
        self.runAll = runAll
        self.stop = stop
        self.format = format
        self.explain = explain
        self.showHistory = showHistory
        self.newTab = newTab
        self.closeTab = closeTab
        self.reopenClosedTab = reopenClosedTab
        self.nextTab = nextTab
        self.previousTab = previousTab
        self.selectTab = selectTab
        self.commitChanges = commitChanges
        self.toggleFilter = toggleFilter
        self.canRun = canRun
        self.canStop = canStop
        self.canFormat = canFormat
        self.canExplain = canExplain
        self.canManageTabs = canManageTabs
        self.canReopenClosedTab = canReopenClosedTab
        self.tabCount = tabCount
        self.canCommitChanges = canCommitChanges
        self.canToggleFilter = canToggleFilter
    }
}

public struct QueryMenuActionsKey: FocusedValueKey {
    public typealias Value = QueryMenuActions
}

extension FocusedValues {
    public var queryMenuActions: QueryMenuActions? {
        get { self[QueryMenuActionsKey.self] }
        set { self[QueryMenuActionsKey.self] = newValue }
    }
}

/// 宿主 App 挂到 Scene 上的 Query 菜单：执行 / 格式化 / 历史 / 标签管理 /
/// 网格提交与筛选。未注入动作（工作区不可见）时整组禁用。
///
/// ⌘W 在编辑器上下文关闭当前标签；菜单项禁用时按键回落到系统关闭窗口。
public struct DatabaseQueryCommands: Commands {
    @FocusedValue(\.queryMenuActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandMenu(pluginLocalization.string("Query")) {
            Button(pluginLocalization.string("Run")) {
                actions?.run()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actions?.canRun != true)

            Button(pluginLocalization.string("Run All")) {
                actions?.runAll()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(actions?.canRun != true)

            Button(pluginLocalization.string("Stop")) {
                actions?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(actions?.canStop != true)

            Divider()

            Button(pluginLocalization.string("Format")) {
                actions?.format()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(actions?.canFormat != true)

            Button(pluginLocalization.string("Explain")) {
                actions?.explain()
            }
            .disabled(actions?.canExplain != true)

            Divider()

            Button(pluginLocalization.string("History")) {
                actions?.showHistory()
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button(pluginLocalization.string("New Tab")) {
                actions?.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions?.canManageTabs != true)

            Button(pluginLocalization.string("Close Tab")) {
                actions?.closeTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions?.canManageTabs != true)

            Button(pluginLocalization.string("Reopen Closed Tab")) {
                actions?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(actions?.canReopenClosedTab != true)

            Divider()

            Button(pluginLocalization.string("Next Tab")) {
                actions?.nextTab()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(actions?.canManageTabs != true || (actions?.tabCount ?? 0) < 2)

            Button(pluginLocalization.string("Previous Tab")) {
                actions?.previousTab()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(actions?.canManageTabs != true || (actions?.tabCount ?? 0) < 2)

            ForEach(0..<9, id: \.self) { index in
                Button(String(format: pluginLocalization.string("Select Tab %d"), index + 1)) {
                    actions?.selectTab(index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(actions?.canManageTabs != true || (actions?.tabCount ?? 0) <= index)
            }

            Divider()

            Button(pluginLocalization.string("Commit Changes")) {
                actions?.commitChanges()
            }
            .disabled(actions?.canCommitChanges != true)

            Button(pluginLocalization.string("Toggle Filter")) {
                actions?.toggleFilter()
            }
            .disabled(actions?.canToggleFilter != true)
        }
    }
}