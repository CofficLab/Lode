import AppKit
import ProviderEditor
import ProviderStorage
import EditorLanguageRuntime
import EditorService
import EditorSource
import KernelCore
import LumiUI
import SwiftUI
import LumiLoggingKit
import os

/// KernelCore 的编辑器宿主：提供与旧宿主相同的 SourceEditor 语法高亮能力。
///
/// 不实现 `PluginDataMigrating`：旧数据目录 `Application Support/<storageDirectoryName>/`
/// 不作搬迁，配置与键位从新目录重新生成。
@MainActor
public final class CodeEditorHostPlugin: SuperPlugin, SuperLog {
    nonisolated static let logger = Logger(subsystem: "com.coffic.lumi.plugin.editor-host", category: "EditorHost")
    public let id = "com.coffic.lumi.plugin.editor-host"
    public let order = 1
    public let dependencies: [String] = []
    public let metadata = PluginMetadata(
        id: "com.coffic.lumi.plugin.editor-host",
        name: CodeEditorHostLocalization.string("Editor Host"),
        description: CodeEditorHostLocalization.string("Provides shared source editing and syntax highlighting."),
        version: "2.0.0",
        category: .editor,
        stage: .preview,
        policy: .alwaysOn
    )

    public init() {}

    private var editorService: EditorService?
    private var editorAdapter: EditorProvidingV2Adapter?
    private var embeddedEditorProvider: EmbeddedEditorSurfaceProvider?

    public func onBoot(kernel: KernelCoreContainer) throws {
        // 存储路径注入必须早于任何 EditorService / Store 的首次访问：
        // `EditorConfigStore.store` 是 static let，首次访问即固化路径。
        if let storage = kernel.resolveProvider((any StorageProviding).self) {
            EditorSettingsLifecycle.hostPersistenceRootURL = {
                storage.pluginDataDirectory(for: self.id)
            }
        }

        let registry = EditorExtensionRegistry()
        let service = EditorService(editorExtensionRegistry: registry)
        let contributions = EditorContributionRegistry(registry: registry)
        let adapter = EditorProvidingV2Adapter(service: service, extensions: contributions)
        adapter.surfaceBox.makeView = { [weak service] in
            guard let service else {
                return AnyView(EditorHostUnavailableView())
            }
            return AnyView(EditorSurfaceView(state: service.state))
        }
        let embeddedProvider = EmbeddedEditorSurfaceProvider(service: service)

        try kernel.registerProvider(EditorService.self, service)
        try kernel.registerProvider(EditorProviding.self, adapter)
        try kernel.registerProvider(EditorSurfaceProviding.self, adapter.surface)
        try kernel.registerProvider(EditorEmbeddedEditorProviding.self, embeddedProvider)

        editorService = service
        editorAdapter = adapter
        embeddedEditorProvider = embeddedProvider
    }

    public func onShutdown(kernel: KernelCoreContainer) throws {
        editorService?.cleanupForTeardown()
        kernel.unregisterProvider(EditorEmbeddedEditorProviding.self)
        kernel.unregisterProvider(EditorSurfaceProviding.self)
        kernel.unregisterProvider(EditorProviding.self)
        kernel.unregisterProvider(EditorService.self)
        embeddedEditorProvider = nil
        editorAdapter = nil
        editorService = nil
    }
}

private struct EditorHostUnavailableView: View {
    var body: some View {
        AppEmptyState(
            icon: "exclamationmark.triangle",
            title: CodeEditorHostLocalization.string("Editor unavailable"),
            description: CodeEditorHostLocalization.string("The editor service is no longer available.")
        )
    }
}

@MainActor
private final class EmbeddedEditorSurfaceProvider: EditorEmbeddedEditorProviding {
    private let service: EditorService

    init(service: EditorService) { self.service = service }

    func makeEmbeddedEditorView(text: Binding<String>, options: EditorEmbeddedEditorOptions) -> AnyView {
        makeEmbeddedEditorView(text: text, options: options, cursorLocation: nil, selectionRange: nil)
    }

    func makeEmbeddedEditorView(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        cursorLocation: Binding<Int>?
    ) -> AnyView {
        makeEmbeddedEditorView(text: text, options: options, cursorLocation: cursorLocation, selectionRange: nil)
    }

    func makeEmbeddedEditorView(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        cursorLocation: Binding<Int>?,
        selectionRange: Binding<NSRange>?
    ) -> AnyView {
        AnyView(EmbeddedEditorHostView(
            text: text,
            options: options,
            language: service.editorExtensions.languageRegistry.context(for: options.languageID) ?? .plainText,
            cursorLocation: cursorLocation,
            selectionRange: selectionRange
        ))
    }
}

private struct EmbeddedEditorHostView: View {
    @Binding var text: String
    let options: EditorEmbeddedEditorOptions
    let language: EditorLanguageContext
    var cursorLocation: Binding<Int>? = nil
    var selectionRange: Binding<NSRange>? = nil
    @State private var editorState = SourceEditorState()
    @State private var completionAdapter: EditorCompletionSuggestionAdapter?
    /// 诊断标记 + 选区跳转协调器：稳定实例，避免每次渲染重建强调层。
    @State private var diagnosticsCoordinator: EmbeddedEditorDiagnosticsCoordinator?
    /// 稳定的高亮 Provider 实例：超大文档降级时切到空数组，恢复时切回，避免每次渲染重建。
    @State private var treeSitterClient = TreeSitterClient()
    @Environment(\.colorScheme) private var colorScheme

    init(
        text: Binding<String>,
        options: EditorEmbeddedEditorOptions,
        language: EditorLanguageContext,
        cursorLocation: Binding<Int>? = nil,
        selectionRange: Binding<NSRange>? = nil
    ) {
        self._text = text
        self.options = options
        self.language = language
        self.cursorLocation = cursorLocation
        self.selectionRange = selectionRange
        self._completionAdapter = State(initialValue: options.completionProvider.map {
            EditorCompletionSuggestionAdapter(provider: $0, languageID: options.languageID)
        })
        self._diagnosticsCoordinator = State(initialValue: EmbeddedEditorDiagnosticsCoordinator(diagnostics: options.diagnostics))
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: configuration,
            state: $editorState,
            highlightProviders: isLargeDocument ? [] : [treeSitterClient],
            foldProvider: makeFoldProvider(),
            coordinators: diagnosticsCoordinator.map { [$0] } ?? [],
            completionDelegate: completionAdapter
        )
            .onAppear {
                publishPositions(editorState.cursorPositions)
                diagnosticsCoordinator?.refresh(text: text)
            }
            .onChange(of: editorState.cursorPositions) { _, newValue in publishPositions(newValue) }
            .onChange(of: text) { _, newValue in diagnosticsCoordinator?.refresh(text: newValue) }
            .onChange(of: selectionRange?.wrappedValue) { _, newValue in
                if let newValue { diagnosticsCoordinator?.focus(newValue) }
            }
    }

    /// 文档是否达到超大文档阈值（关闭高亮/折叠/解析）。
    private var isLargeDocument: Bool {
        text.utf16.count >= EditorDocumentLimits.largeDocumentUTF16Threshold
    }

    /// 由插件提供的折叠区间构造通用折叠 Provider；超大文档时返回空区间自行禁用折叠。
    private func makeFoldProvider() -> RangeLineFoldProvider? {
        guard let foldRanges = options.foldRanges else { return nil }
        return RangeLineFoldProvider { text in
            text.utf16.count >= EditorDocumentLimits.largeDocumentUTF16Threshold ? [] : foldRanges(text)
        }
    }

    /// 把编辑器光标（caret/选区起点）与选区范围换算成 UTF-16 偏移回写给消费方。
    private func publishPositions(_ positions: [CursorPosition]?) {
        guard let first = positions?.first else { return }
        let offset = first.range.location != NSNotFound
            ? first.range.location
            : utf16Offset(line: first.start.line, column: first.start.column)
        if let cursorLocation, cursorLocation.wrappedValue != offset {
            cursorLocation.wrappedValue = offset
        }
        if let selectionRange {
            let range = first.range.location != NSNotFound ? first.range : NSRange(location: offset, length: 0)
            if selectionRange.wrappedValue != range {
                selectionRange.wrappedValue = range
            }
        }
    }

    /// 行/列（均 1 起）→ UTF-16 偏移；range 缺失时的兜底换算。
    private func utf16Offset(line: Int, column: Int) -> Int {
        guard line > 0, column > 0 else { return 0 }
        var offset = 0
        for (index, lineText) in text.components(separatedBy: "\n").enumerated() {
            let lineLength = (lineText as NSString).length
            if index + 1 == line {
                return min(offset + min(column - 1, lineLength), text.utf16.count)
            }
            offset += lineLength + 1
        }
        return min(offset, text.utf16.count)
    }

    private var configuration: SourceEditorConfiguration {
        let resolved = LumiUIThemeRegistry.shared.resolvedEditorSyntax(colorScheme: colorScheme)
        let palette = resolved?.palette ?? .standard(isDark: colorScheme == .dark)
        return SourceEditorConfiguration(
            appearance: .init(
                theme: EditorSyntaxPaletteAdapter.makeEditorTheme(from: palette),
                themeIdentifier: resolved?.themeId ?? "embedded-\(options.languageID)-\(colorScheme == .dark ? "dark" : "light")",
                useThemeBackground: options.useThemeBackground,
                font: .monospacedSystemFont(ofSize: options.fontSize > 0 ? options.fontSize : NSFont.systemFontSize, weight: .regular),
                wrapLines: options.wrapLines,
                tabWidth: 4
            ),
            behavior: .init(isEditable: options.isEditable, isSelectable: options.isSelectable, highlightDebounceMilliseconds: 150),
            layout: .init(additionalTextInsets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)),
            peripherals: .init(
                showGutter: options.showGutter,
                showMinimap: false,
                showReformattingGuide: false,
                showFoldingRibbon: options.foldRanges != nil && !isLargeDocument,
                codeSuggestionTriggerCharacters: Set((options.completionProvider?.triggerCharacters ?? []).map { String($0) })
            )
        )
    }
}
