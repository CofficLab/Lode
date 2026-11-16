import AppKit
import SwiftUI
import ProviderEditor
import EditorSource

/// 把中立 ``EditorCompletionProvider`` 桥接到 SourceEditor 既有补全弹层（``CodeSuggestionDelegate``）。
///
/// 宿主侧通用适配器：任意语言 Provider 都可经此接入 AppKit 建议窗口，无需各自实现弹层。
/// 由 ``EmbeddedEditorHostView`` 以 `@State` 强持有（`SourceEditor.completionDelegate` 为 weak）。
@MainActor
final class EditorCompletionSuggestionAdapter: CodeSuggestionDelegate {
    private let provider: any EditorCompletionProvider
    private let languageID: String
    private var cachedEntries: [CodeSuggestionEntry] = []

    private static let identifierSet: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_$")
        return set
    }()

    init(provider: any EditorCompletionProvider, languageID: String) {
        self.provider = provider
        self.languageID = languageID
    }

    func completionTriggerCharacters() -> Set<String> {
        Set(provider.triggerCharacters.map { String($0) })
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        let text = textView.text
        let offset = caretOffset(textView, cursorPosition, text)
        let (prefix, _) = prefixInfo(text, offset)
        let request = EditorCompletionRequest(
            context: EditorFeatureRequestContext(uri: nil, languageID: languageID, revision: 0),
            position: editorPosition(offset, text),
            prefix: prefix,
            isTypeContext: false,
            documentText: text
        )
        let items = await provider.completions(for: request)
        guard !items.isEmpty else {
            cachedEntries = []
            return nil
        }
        let entries: [CodeSuggestionEntry] = items.map { Entry(item: $0) }
        cachedEntries = entries
        return (cursorPosition, entries)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        let text = textView.text
        let offset = caretOffset(textView, cursorPosition, text)
        let (prefix, _) = prefixInfo(text, offset)
        let lower = prefix.lowercased()
        let filtered = cachedEntries.filter { lower.isEmpty || $0.label.lowercased().hasPrefix(lower) }
        return filtered.isEmpty ? nil : filtered
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let entry = item as? Entry else { return }
        let text = textView.text
        let ns = text as NSString
        let rawCaret = cursorPosition?.range.location ?? textView.cursorPositions.first?.range.location ?? ns.length
        let caret = rawCaret == NSNotFound ? ns.length : min(rawCaret, ns.length)
        let (_, start) = prefixInfo(text, caret)
        let replaceRange = NSRange(location: start, length: caret - start)
        let insert = entry.insertText
        textView.textView.textStorage.replaceCharacters(in: replaceRange, with: insert)
        let newCaret = start + (insert as NSString).length
        textView.setCursorPositions([CursorPosition(range: NSRange(location: newCaret, length: 0))])
        cachedEntries = []
    }

    // MARK: - 文本几何

    private func caretOffset(_ textView: TextViewController, _ position: CursorPosition, _ text: String) -> Int {
        let length = (text as NSString).length
        if position.range.location != NSNotFound {
            return min(position.range.location, length)
        }
        if let resolved = textView.resolveCursorPosition(position), resolved.range.location != NSNotFound {
            return min(resolved.range.location, length)
        }
        return length
    }

    /// 光标处的标识符前缀及其起点（向后扫描，遇点号/空白/引号停止，保留限定符）。
    private func prefixInfo(_ text: String, _ offset: Int) -> (prefix: String, start: Int) {
        let ns = text as NSString
        let clamped = max(0, min(offset, ns.length))
        var start = clamped
        while start > 0, Self.isIdentifierUnit(ns.character(at: start - 1)) { start -= 1 }
        return (ns.substring(with: NSRange(location: start, length: clamped - start)), start)
    }

    private static func isIdentifierUnit(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return identifierSet.contains(scalar)
    }

    /// 绝对 UTF-16 偏移 → zero-based 行号 + 行内 UTF-16 偏移。
    private func editorPosition(_ offset: Int, _ text: String) -> EditorPosition {
        let ns = text as NSString
        let clamped = max(0, min(offset, ns.length))
        var line = 0
        var lineStart = 0
        var i = 0
        while i < clamped {
            if ns.character(at: i) == 10 {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        return EditorPosition(line: line, character: clamped - lineStart)
    }

    // MARK: - 弹层条目

    struct Entry: CodeSuggestionEntry {
        let label: String
        let detail: String?
        let documentation: String? = nil
        let pathComponents: [String]? = nil
        let targetPosition: CursorPosition? = nil
        let sourcePreview: String? = nil
        let image: Image
        let imageColor: Color
        let deprecated: Bool = false
        let insertText: String

        init(item: EditorCompletionItem) {
            label = item.label
            detail = item.detail
            insertText = item.insertText
            switch item.kind {
            case .keyword:
                image = Image(systemName: "textformat")
                imageColor = .purple
            case .struct, .class, .module:
                image = Image(systemName: "tablecells")
                imageColor = .blue
            case .field, .property, .variable:
                image = Image(systemName: "list.bullet.rectangle")
                imageColor = .green
            case .function, .method:
                image = Image(systemName: "function")
                imageColor = .orange
            default:
                image = Image(systemName: "textformat.size")
                imageColor = .secondary
            }
        }
    }
}