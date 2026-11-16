import AppKit
import EditorLanguageRuntime
import EditorSource
import EditorTextView
import ProviderEditor
import Testing
@testable import PluginCodeEditorHost

// P3-7 运行时验证：诊断协调器把标记真实落到 EmphasisManager 下划线层与行号槽圆点，
// 并承接选区跳转。使用真实 TextViewController（含 loadView 后的 gutter），非纯逻辑桩。

@MainActor
struct EmbeddedEditorDiagnosticsCoordinatorTests {
    /// 测试用扫描闭包：'(' → error，西里尔 а → warning（与插件扫描器口径一致的子集）。
    private nonisolated static func scan(_ text: String) -> [EditorEmbeddedDiagnostic] {
        let ns = text as NSString
        var marks: [EditorEmbeddedDiagnostic] = []
        let paren = UInt16(UnicodeScalar("(").value)
        let cyrillicA = UInt16(UnicodeScalar("а").value)
        for index in 0..<ns.length {
            let unit = ns.character(at: index)
            if unit == paren {
                marks.append(EditorEmbeddedDiagnostic(range: NSRange(location: index, length: 1), severity: .error))
            } else if unit == cyrillicA {
                marks.append(EditorEmbeddedDiagnostic(range: NSRange(location: index, length: 1), severity: .warning))
            }
        }
        return marks
    }

    private func makeController(
        text: String,
        coordinator: EmbeddedEditorDiagnosticsCoordinator
    ) -> TextViewController {
        let theme = EditorTheme(
            text: .init(color: .textColor),
            insertionPoint: .textColor,
            invisibles: .init(color: .secondaryLabelColor),
            background: .textBackgroundColor,
            lineHighlight: .controlBackgroundColor,
            selection: .selectedTextBackgroundColor,
            keywords: .init(color: .systemBlue),
            commands: .init(color: .systemPurple),
            types: .init(color: .systemTeal),
            attributes: .init(color: .systemOrange),
            variables: .init(color: .labelColor),
            values: .init(color: .systemGreen),
            numbers: .init(color: .systemPink),
            strings: .init(color: .systemRed),
            characters: .init(color: .systemRed),
            comments: .init(color: .secondaryLabelColor)
        )
        let config = SourceEditorConfiguration(
            appearance: .init(
                theme: theme,
                themeIdentifier: "test",
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            )
        )
        let controller = TextViewController(
            string: text,
            language: .plainText,
            configuration: config,
            cursorPositions: [],
            highlightProviders: [],
            coordinators: [coordinator]
        )
        // 触发 loadView，建立 scrollView / gutterView。
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        return controller
    }

    @Test func refreshAppliesUnderlineEmphasesAndGutterMarks() throws {
        let coordinator = EmbeddedEditorDiagnosticsCoordinator(diagnostics: Self.scan)
        let text = "SELECT а FROM t\nWHERE (x = 1;"
        let controller = makeController(text: text, coordinator: coordinator)
        coordinator.refresh(text: text)

        let emphases = try #require(controller.textView.emphasisManager).getEmphases(for: "embedded.diagnostics")
        #expect(emphases.count == 2)
        #expect(emphases.contains { $0.range.location == 7 && $0.style == .underline(color: .systemOrange) })
        let parenOffset = (text as NSString).range(of: "(").location
        #expect(emphases.contains { $0.range.location == parenOffset && $0.style == .underline(color: .systemRed) })

        // 行号槽：第 1 行 warning 橙点，第 2 行 error 红点。
        #expect(controller.gutterDiagnosticMarks == [1: .systemOrange, 2: .systemRed])
    }

    @Test func errorWinsOverWarningOnSharedLine() {
        let coordinator = EmbeddedEditorDiagnosticsCoordinator(diagnostics: Self.scan)
        let text = "( а"
        let controller = makeController(text: text, coordinator: coordinator)
        coordinator.refresh(text: text)
        #expect(controller.gutterDiagnosticMarks == [1: .systemRed])
    }

    @Test func cleanTextClearsEmphasesAndGutterMarks() throws {
        let coordinator = EmbeddedEditorDiagnosticsCoordinator(diagnostics: Self.scan)
        let controller = makeController(text: "SELECT (a", coordinator: coordinator)
        coordinator.refresh(text: "SELECT (a")
        #expect(controller.gutterDiagnosticMarks.isEmpty == false)

        controller.setText("SELECT a;")
        coordinator.refresh(text: "SELECT a;")
        let emphases = try #require(controller.textView.emphasisManager).getEmphases(for: "embedded.diagnostics")
        #expect(emphases.isEmpty)
        #expect(controller.gutterDiagnosticMarks.isEmpty)
    }

    @Test func focusMovesEditorSelection() throws {
        let coordinator = EmbeddedEditorDiagnosticsCoordinator(diagnostics: Self.scan)
        let text = "SELECT а FROM t\nWHERE (x = 1;"
        let controller = makeController(text: text, coordinator: coordinator)
        coordinator.refresh(text: text)

        let parenOffset = (text as NSString).range(of: "(").location
        let target = NSRange(location: parenOffset, length: 1)
        coordinator.focus(target)
        #expect(controller.textView.selectionManager.textSelections.map(\.range) == [target])
    }

    @Test func focusIgnoresOutOfRangeAndNotFound() {
        let coordinator = EmbeddedEditorDiagnosticsCoordinator(diagnostics: Self.scan)
        let text = "SELECT (a"
        let controller = makeController(text: text, coordinator: coordinator)
        coordinator.refresh(text: text)
        coordinator.focus(NSRange(location: 0, length: 1))
        let before = controller.textView.selectionManager.textSelections.map(\.range)

        coordinator.focus(NSRange(location: 9_999, length: 1))
        coordinator.focus(NSRange(location: NSNotFound, length: 0))
        #expect(controller.textView.selectionManager.textSelections.map(\.range) == before)
    }

    @Test func destroyClearsAllMarks() throws {
        let coordinator = EmbeddedEditorDiagnosticsCoordinator(diagnostics: Self.scan)
        let controller = makeController(text: "SELECT (a", coordinator: coordinator)
        coordinator.refresh(text: "SELECT (a")
        coordinator.destroy()
        let emphases = try #require(controller.textView.emphasisManager).getEmphases(for: "embedded.diagnostics")
        #expect(emphases.isEmpty)
        #expect(controller.gutterDiagnosticMarks.isEmpty)
    }

    @Test func unchangedTextSkipsRescanButReappliesGutterMarks() {
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        let coordinator = EmbeddedEditorDiagnosticsCoordinator { text in
            counter.value += 1
            return Self.scan(text)
        }
        let text = "SELECT (a"
        let controller = makeController(text: text, coordinator: coordinator)
        let afterPrepare = counter.value
        coordinator.refresh(text: text)
        coordinator.refresh(text: text)
        #expect(counter.value == afterPrepare)
        #expect(controller.gutterDiagnosticMarks == [1: .systemRed])
    }
}