import SwiftUI

/// 表网格激活时注入的 Edit 菜单动作（页级复制 + 行粘贴）。
public struct GridEditActions {
    public let copyPageCSV: () -> Void
    public let copyPageMarkdown: () -> Void
    public let pasteRows: () -> Void
    public let canPaste: Bool
    public let findInGrid: () -> Void

    public init(
        copyPageCSV: @escaping () -> Void,
        copyPageMarkdown: @escaping () -> Void,
        pasteRows: @escaping () -> Void,
        canPaste: Bool,
        findInGrid: @escaping () -> Void = {}
    ) {
        self.copyPageCSV = copyPageCSV
        self.copyPageMarkdown = copyPageMarkdown
        self.pasteRows = pasteRows
        self.canPaste = canPaste
        self.findInGrid = findInGrid
    }
}

public struct GridEditActionsKey: FocusedValueKey {
    public typealias Value = GridEditActions
}

extension FocusedValues {
    public var gridEditActions: GridEditActions? {
        get { self[GridEditActionsKey.self] }
        set { self[GridEditActionsKey.self] = newValue }
    }
}

/// 宿主 App 挂到 Scene 上的 Edit 菜单扩展：
/// 表浏览激活时可用页级复制与行粘贴；无网格时禁用。
public struct DatabaseGridEditCommands: Commands {
    @FocusedValue(\.gridEditActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button(pluginLocalization.string("Copy Page as CSV")) {
                actions?.copyPageCSV()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button(pluginLocalization.string("Copy Page as Markdown")) {
                actions?.copyPageMarkdown()
            }
            .disabled(actions == nil)

            Divider()

            Button(pluginLocalization.string("Paste Rows")) {
                actions?.pasteRows()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(actions?.canPaste != true)

            Divider()

            Button(pluginLocalization.string("Find in Grid")) {
                actions?.findInGrid()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}