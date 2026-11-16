import AppKit
import ProviderEditor
import SwiftUI

/// 嵌入式代码/SQL 编辑器。
///
/// 优先使用 Host 提供的 `EditorEmbeddedEditorProviding`（真实语法高亮编辑器）；
/// Host 不可用时退回纯 SwiftUI `TextEditor`（等宽字体，只读时禁用），
/// 保证插件可独立运作。Provider 由 ViewModel 提供，View 不自行解析。
struct EmbeddedCodeEditorView: View {
    @Binding var text: String
    var options: EditorEmbeddedEditorOptions
    var provider: (any EditorEmbeddedEditorProviding)?
    var cursorLocation: Binding<Int>?
    var selectionRange: Binding<NSRange>?

    init(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        provider: (any EditorEmbeddedEditorProviding)? = nil,
        cursorLocation: Binding<Int>? = nil,
        selectionRange: Binding<NSRange>? = nil
    ) {
        self._text = text
        self.options = options
        self.provider = provider
        self.cursorLocation = cursorLocation
        self.selectionRange = selectionRange
    }

    var body: some View {
        if let provider {
            provider.makeEmbeddedEditorView(text: $text, options: options, cursorLocation: cursorLocation, selectionRange: selectionRange)
                .accessibilityLabel(pluginLocalization.string("SQL Editor"))
        } else {
            fallbackEditor
                .accessibilityLabel(pluginLocalization.string("SQL Editor"))
        }
    }

    /// 无 Host 编辑器时的降级实现：等宽字体纯文本编辑器。
    private var fallbackEditor: some View {
        TextEditor(text: $text)
            .font(.system(size: options.fontSize > 0 ? options.fontSize : NSFont.systemFontSize, design: .monospaced))
            .disabled(!options.isEditable)
    }
}
