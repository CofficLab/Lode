import AppKit
import EditorSource
import EditorTextView
import ProviderEditor

/// 嵌入式编辑器诊断协调器。
///
/// 两个职责：
/// 1. 把消费方插件提供的诊断扫描结果（``EditorEmbeddedEditorOptions/diagnostics``）
///    绘制为编辑器内的下划线标记（error 红 / warning 橙），文本变化时整组替换。
/// 2. 承接消费方通过选区绑定发起的「跳转到诊断」请求：把编辑器选区移动到目标范围。
///
/// 标记使用 `EmphasisManager` 的独立分组，不与查找/括号配对强调互相干扰。
/// 线程模型沿用宿主既有协调器：协议回调 nonisolated + `MainActor.assumeIsolated`。
final class EmbeddedEditorDiagnosticsCoordinator: TextViewCoordinator, @unchecked Sendable {
    private static let emphasisGroup = "embedded.diagnostics"

    private let diagnostics: (@Sendable (String) -> [EditorEmbeddedDiagnostic])?
    private weak var controller: TextViewController?
    private var lastScannedText: String?
    private var lastMarks: [EditorEmbeddedDiagnostic] = []
    private var lastLineMarks: [Int: NSColor] = [:]

    init(diagnostics: (@Sendable (String) -> [EditorEmbeddedDiagnostic])?) {
        self.diagnostics = diagnostics
    }

    // MARK: - TextViewCoordinator

    nonisolated func prepareCoordinator(controller: TextViewController) {
        MainActor.assumeIsolated {
            self.controller = controller
            self.refresh(text: controller.text)
        }
    }

    nonisolated func textViewDidChangeText(controller: TextViewController) {
        MainActor.assumeIsolated {
            self.refresh(text: controller.text)
        }
    }

    nonisolated func destroy() {
        MainActor.assumeIsolated {
            self.controller?.textView.emphasisManager?.removeEmphases(for: Self.emphasisGroup)
            self.controller?.setGutterDiagnosticMarks([:])
            self.controller = nil
            self.lastScannedText = nil
            self.lastMarks = []
            self.lastLineMarks = [:]
        }
    }

    // MARK: - 标记

    /// 重新扫描并整组替换下划线标记与行号槽圆点；文本未变化时跳过扫描，
    /// 但仍重放行号槽标记（覆盖 prepare 阶段 gutter 尚未加载的时序）。
    @MainActor
    func refresh(text: String) {
        guard let diagnostics, let controller else { return }
        if text != lastScannedText {
            lastScannedText = text
            lastMarks = diagnostics(text)
            lastLineMarks = Self.lineMarks(for: lastMarks, in: text)
            let emphases = lastMarks.map { mark in
                Emphasis(
                    range: mark.range,
                    style: .underline(color: Self.color(for: mark.severity)),
                    flash: false,
                    inactive: false
                )
            }
            controller.textView.emphasisManager?.replaceEmphases(emphases, for: Self.emphasisGroup)
        }
        controller.setGutterDiagnosticMarks(lastLineMarks)
    }

    /// 诊断范围 → 行号（1 起）→ 颜色；同一行 error 优先于 warning。
    /// 单次遍历文本按 UTF-16 偏移定位行，避免逐条诊断重复扫描。
    private static func lineMarks(for marks: [EditorEmbeddedDiagnostic], in text: String) -> [Int: NSColor] {
        guard !marks.isEmpty else { return [:] }
        let sorted = marks.sorted { $0.range.location < $1.range.location }
        var result: [Int: NSColor] = [:]
        var index = 0
        var line = 1
        var offset = 0

        func assign(_ mark: EditorEmbeddedDiagnostic, toLine line: Int) {
            if result[line] == nil || mark.severity == .error {
                result[line] = color(for: mark.severity)
            }
        }

        for scalar in text.unicodeScalars {
            while index < sorted.count, sorted[index].range.location <= offset {
                assign(sorted[index], toLine: line)
                index += 1
            }
            if index >= sorted.count { break }
            if scalar == "\n" { line += 1 }
            offset += scalar.utf16.count
        }
        while index < sorted.count {
            assign(sorted[index], toLine: line)
            index += 1
        }
        return result
    }

    // MARK: - 跳转

    /// 把编辑器选区移动到目标范围（诊断条点击跳转）。
    /// 与当前选区相同时不动作，避免「回写绑定 → 再次应用」的循环。
    @MainActor
    func focus(_ range: NSRange) {
        guard let controller, range.location != NSNotFound else { return }
        guard range.location + range.length <= controller.text.utf16.count else { return }
        if controller.cursorPositions.first?.range == range { return }
        controller.textView.selectionManager.setSelectedRanges([range])
        controller.textView.scrollSelectionToVisible()
    }

    private static func color(for severity: EditorEmbeddedDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error:
            return .systemRed
        case .warning:
            return .systemOrange
        }
    }
}