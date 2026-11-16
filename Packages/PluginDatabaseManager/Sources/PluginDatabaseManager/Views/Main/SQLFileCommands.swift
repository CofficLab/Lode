import SwiftUI

/// SQL 编辑器激活时注入的 File 菜单动作（打开 / 保存 / 另存为）。
///
/// `canSave` 仅在编辑器可见（已连接且未打开表浏览）时为真，避免与表网格
/// 自带的 ⌘S 保存改动冲突；表浏览激活时本组 Save 禁用，网格 ⌘S 生效。
public struct SQLFileActions {
    public let open: () -> Void
    public let save: () -> Void
    public let saveAs: () -> Void
    public let canOpen: Bool
    public let canSave: Bool

    public init(
        open: @escaping () -> Void,
        save: @escaping () -> Void,
        saveAs: @escaping () -> Void,
        canOpen: Bool,
        canSave: Bool
    ) {
        self.open = open
        self.save = save
        self.saveAs = saveAs
        self.canOpen = canOpen
        self.canSave = canSave
    }
}

public struct SQLFileActionsKey: FocusedValueKey {
    public typealias Value = SQLFileActions
}

extension FocusedValues {
    public var sqlFileActions: SQLFileActions? {
        get { self[SQLFileActionsKey.self] }
        set { self[SQLFileActionsKey.self] = newValue }
    }
}

/// 宿主 App 挂到 Scene 上的 File 菜单扩展：打开 .sql、保存、另存为。
public struct DatabaseSQLFileCommands: Commands {
    @FocusedValue(\.sqlFileActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(pluginLocalization.string("Open SQL File…")) {
                actions?.open()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(actions?.canOpen != true)

            Divider()

            Button(pluginLocalization.string("Save")) {
                actions?.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(actions?.canSave != true)

            Button(pluginLocalization.string("Save As…")) {
                actions?.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(actions?.canSave != true)
        }
    }
}