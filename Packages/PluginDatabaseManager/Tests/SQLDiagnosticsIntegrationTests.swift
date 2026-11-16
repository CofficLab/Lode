import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P3-7 结构化诊断（VM 逻辑层，无头）：
// queryText 变化驱动诊断、点击跳转写选区绑定、Host 标记映射、超大文档降级、标签切换重扫。

@MainActor
@Suite(.serialized)
struct SQLDiagnosticsIntegrationTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.sqldiag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeVM() -> DatabaseViewModel {
        DatabaseViewModel(loadSavedConfigs: false, manager: DatabaseManagerCore(), workspaceDefaults: makeDefaults())
    }

    @Test func queryTextChangePublishesDiagnostics() {
        let vm = makeVM()
        vm.queryText = "SELECT (a FROM t;"
        #expect(vm.sqlDiagnostics.count == 1)
        #expect(vm.sqlDiagnostics[0].kind == .unmatchedOpeningBracket)
    }

    @Test func cleanTextClearsDiagnostics() {
        let vm = makeVM()
        vm.queryText = "SELECT (a FROM t;"
        #expect(!vm.sqlDiagnostics.isEmpty)
        vm.queryText = "SELECT a FROM t;"
        #expect(vm.sqlDiagnostics.isEmpty)
    }

    @Test func confusableCharacterPublishesWarning() {
        let vm = makeVM()
        vm.queryText = "SELECT а FROM t;"
        #expect(vm.sqlDiagnostics.count == 1)
        #expect(vm.sqlDiagnostics[0].severity == .warning)
        #expect(vm.sqlDiagnostics[0].kind == .confusableCharacter(ascii: "a"))
    }

    @Test func jumpSetsCursorAndSelectionBindings() {
        let vm = makeVM()
        vm.queryText = "SELECT а FROM t;"
        let diagnostic = vm.sqlDiagnostics[0]
        vm.jumpToSQLDiagnostic(diagnostic)
        #expect(vm.editorCursorLocation == diagnostic.range.location)
        #expect(vm.editorSelectionRange == diagnostic.range)
    }

    @Test func embeddedMappingPreservesRangesAndSeverity() {
        let text = "SELECT а FROM t WHERE (x = 1;"
        let scanned = SQLStructuralDiagnostics.scan(text)
        let marks = DatabaseViewModel.embeddedSQLDiagnostics(text)
        #expect(marks.count == scanned.count)
        for (mark, diagnostic) in zip(marks, scanned) {
            #expect(mark.range == diagnostic.range)
            #expect(mark.severity == (diagnostic.severity == .error ? .error : .warning))
        }
        #expect(marks.contains { $0.severity == .warning })
        #expect(marks.contains { $0.severity == .error })
    }

    @Test func largeDocumentDisablesDiagnostics() {
        let vm = makeVM()
        let large = String(repeating: "a", count: EditorDocumentGuard.largeDocumentUTF16Threshold) + "("
        vm.queryText = large
        #expect(vm.sqlDiagnostics.isEmpty)
        #expect(DatabaseViewModel.embeddedSQLDiagnostics(large).isEmpty)
    }

    @Test func newTabRescansDiagnostics() {
        let vm = makeVM()
        vm.queryText = "SELECT (a FROM t;"
        #expect(!vm.sqlDiagnostics.isEmpty)
        vm.newQueryTab()
        #expect(vm.sqlDiagnostics.isEmpty)
    }

    @Test func switchingBackToDirtyTabRestoresItsDiagnostics() {
        let vm = makeVM()
        vm.queryText = "SELECT (a FROM t;"
        let firstTab = vm.workspace.activeTabID
        vm.newQueryTab()
        #expect(vm.sqlDiagnostics.isEmpty)
        vm.selectQueryTab(id: firstTab)
        #expect(vm.sqlDiagnostics.count == 1)
        #expect(vm.sqlDiagnostics[0].kind == .unmatchedOpeningBracket)
    }
}