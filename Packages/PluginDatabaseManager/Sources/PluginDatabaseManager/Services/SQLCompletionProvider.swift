import Foundation
import ProviderEditor

/// SQL schema 感知补全 Provider（中立 ``EditorCompletionProvider`` 契约）。
///
/// 由 ViewModel 持有并注入嵌入式编辑器选项；Host 侧适配器把本 Provider 的候选
/// 桥接到 SourceEditor 的补全弹层。触发字符 `.`；字母/数字前缀触发由宿主引擎负责。
/// 内置 150ms 级防抖（可被后续按键取消），元数据走连接级 LRU 缓存。
@MainActor
public final class SQLCompletionProvider: EditorCompletionProvider {
    public nonisolated let id = "database.sql.completion"
    public nonisolated let triggerCharacters: Set<Character> = ["."]

    private let manager: DatabaseManagerCore
    private let cache: SQLCompletionMetadataCache
    private let configResolver: @MainActor () -> DatabaseConfig?
    private let debounceNanoseconds: UInt64

    public init(
        manager: DatabaseManagerCore,
        schemaCache: SchemaCacheService,
        configResolver: @escaping @MainActor () -> DatabaseConfig?,
        debounceNanoseconds: UInt64 = 150_000_000
    ) {
        self.manager = manager
        self.cache = SQLCompletionMetadataCache(schemaCache: schemaCache)
        self.configResolver = configResolver
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// 结构变更（DDL）后失效该连接的补全元数据。
    public func invalidate(configId: UUID) {
        cache.invalidate(configId: configId)
    }

    public func invalidateAll() {
        cache.invalidateAll()
    }

    public func completions(for request: EditorCompletionRequest) async -> [EditorCompletionItem] {
        guard let config = configResolver(), config.type != .redis else { return [] }
        let text = request.documentText ?? ""

        if debounceNanoseconds > 0 {
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return [] }
        }
        guard !Task.isCancelled else { return [] }
        guard let connection = await manager.getConnection(for: config.id) else { return [] }

        let metadata: SQLCompletionMetadata
        do {
            metadata = try await cache.metadata(for: config, connection: connection)
        } catch {
            return []
        }

        let offset = Self.utf16Offset(of: request.position, in: text)
        let candidates = SQLCompletionEngine.candidates(
            in: text,
            utf16Offset: offset,
            metadata: metadata,
            dialect: config.type
        )
        return candidates.map { candidate in
            EditorCompletionItem(
                label: candidate.label,
                insertText: candidate.insertText,
                detail: candidate.detail,
                kind: Self.itemKind(candidate.kind),
                priority: candidate.priority
            )
        }
    }

    static func itemKind(_ kind: SQLCompletionCandidate.Kind) -> EditorCompletionItem.Kind {
        switch kind {
        case .keyword: return .keyword
        case .table: return .struct
        case .column: return .field
        case .schema: return .module
        case .alias: return .variable
        }
    }

    /// zero-based 行号 + 行内 UTF-16 偏移 → 文档绝对 UTF-16 偏移。
    static func utf16Offset(of position: EditorPosition, in text: String) -> Int {
        let ns = text as NSString
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for (index, lineText) in lines.enumerated() {
            if index == position.line {
                return min(offset + max(0, position.character), ns.length)
            }
            offset += (lineText as NSString).length + 1
        }
        return min(offset, ns.length)
    }
}