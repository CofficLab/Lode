import SwiftUI
import Foundation

/// 嵌入式编辑器选项（重构方案 §17.2）。
///
/// 由 Feature 插件（如 DatabaseManagerPlugin）描述其内嵌 SQL/代码编辑需求，
/// 与具体编辑器实现（`EditorService` / `EditorSource`）解耦。
public struct EditorEmbeddedEditorOptions {
    /// 语言标识（如 `"sql"`），由 Host 解析为语法/高亮上下文。
    public var languageID: String
    /// 是否允许编辑（false = 只读展示）。
    public var isEditable: Bool
    /// 是否允许选择文本。
    public var isSelectable: Bool
    /// 是否自动换行。
    public var wrapLines: Bool
    /// 是否显示行号槽。
    public var showGutter: Bool
    /// 字号；0 表示使用系统默认字号。
    public var fontSize: CGFloat
    /// 是否使用语法主题背景色。
    public var useThemeBackground: Bool
    /// 补全 Provider（如 SQL schema 补全）；nil 表示不启用补全弹层。
    public var completionProvider: (any EditorCompletionProvider)?
    /// 折叠区间 Provider：给定文档文本返回可折叠块的 UTF-16 范围（如 SQL 语句/CTE/BEGIN 块）。
    /// nil 表示不启用语法折叠（退回宿主默认行为）。范围须跨多行才会产生折叠。
    public var foldRanges: (@Sendable (String) -> [NSRange])?

    public init(
        languageID: String,
        isEditable: Bool = true,
        isSelectable: Bool = true,
        wrapLines: Bool = true,
        showGutter: Bool = true,
        fontSize: CGFloat = 0,
        useThemeBackground: Bool = true,
        completionProvider: (any EditorCompletionProvider)? = nil,
        foldRanges: (@Sendable (String) -> [NSRange])? = nil
    ) {
        self.languageID = languageID
        self.isEditable = isEditable
        self.isSelectable = isSelectable
        self.wrapLines = wrapLines
        self.showGutter = showGutter
        self.fontSize = fontSize
        self.useThemeBackground = useThemeBackground
        self.completionProvider = completionProvider
        self.foldRanges = foldRanges
    }
}

/// 编辑器文档规模限制（宿主与插件共用，避免阈值两处漂移）。
public enum EditorDocumentLimits {
    /// 超大文档阈值：2,000,000 个 UTF-16 码元。达到/超过即关闭高亮/折叠/解析，仅保留纯文本编辑。
    public static let largeDocumentUTF16Threshold = 2_000_000
}

/// 嵌入式编辑器能力（重构方案 §17.2）。
///
/// Feature 插件通过本能力在自身面板内嵌入一个具备语法高亮的
/// 代码/SQL 编辑器视图，而不直接依赖编辑器实现层。
/// Host（EditorHostPlugin）负责用真实编辑器实现本协议；
/// 未注册时消费方可退回纯 SwiftUI 编辑器。
///
/// 本协议属于 KernelLumi 的 UI 契约分区，允许使用 `AnyView`。
@MainActor
public protocol EditorEmbeddedEditorProviding: AnyObject {
    /// 创建嵌入式编辑器视图。
    ///
    /// - Parameters:
    ///   - text: 文本内容的双向绑定。
    ///   - options: 外观与行为选项。
    /// - Returns: 编辑器视图；Host 未就绪时应返回可用占位，绝不返回 nil。
    func makeEmbeddedEditorView(text: Binding<String>, options: EditorEmbeddedEditorOptions) -> AnyView

    /// 创建嵌入式编辑器视图，并把光标位置回写到 `cursorLocation`。
    ///
    /// - Parameters:
    ///   - text: 文本内容的双向绑定。
    ///   - options: 外观与行为选项。
    ///   - cursorLocation: 光标（caret/选区起点）在 `text` 中的 UTF-16 偏移；
    ///     传 nil 表示不需要追踪。Host 不支持追踪时可忽略此绑定。
    /// - Returns: 编辑器视图；Host 未就绪时应返回可用占位，绝不返回 nil。
    func makeEmbeddedEditorView(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        cursorLocation: Binding<Int>?
    ) -> AnyView

    /// 创建嵌入式编辑器视图，回写光标位置与当前选区范围。
    ///
    /// - Parameters:
    ///   - selectionRange: 当前选区在 `text` 中的 UTF-16 `NSRange`（无选区时 length 为 0）；
    ///     传 nil 表示不需要追踪。Host 不支持追踪时可忽略此绑定。
    func makeEmbeddedEditorView(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        cursorLocation: Binding<Int>?,
        selectionRange: Binding<NSRange>?
    ) -> AnyView
}

public extension EditorEmbeddedEditorProviding {
    /// 默认不追踪光标：转发到无光标版本，保证既有实现无需改动即可兼容。
    func makeEmbeddedEditorView(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        cursorLocation: Binding<Int>?
    ) -> AnyView {
        makeEmbeddedEditorView(text: text, options: options)
    }

    /// 默认不追踪选区：转发到仅光标版本，保证既有实现无需改动即可兼容。
    func makeEmbeddedEditorView(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        cursorLocation: Binding<Int>?,
        selectionRange: Binding<NSRange>?
    ) -> AnyView {
        makeEmbeddedEditorView(text: text, options: options, cursorLocation: cursorLocation)
    }
}
