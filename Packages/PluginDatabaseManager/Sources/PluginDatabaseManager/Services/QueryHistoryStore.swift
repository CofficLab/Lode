import Foundation
import SQLite3

private let historySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 查询历史持久化存储（SQLite FTS5，独立 store 文件）。
///
/// - 全文检索：sql / 连接名 / 库名建 FTS5 索引，搜索按词元前缀匹配（AND）；
/// - 按 (sql, configName, database) 去重，最新在前；去重保留用户置顶标记；
/// - **绝不记录** 含 `CREATE USER` / `ALTER USER` / `SET PASSWORD` 等敏感语句（避免密码落盘）；
/// - 保留期（天）与数量上限清理，置顶条目豁免；
/// - 首次启动把旧版 `UserDefaults` JSON 历史迁移进 SQLite，随后清除旧键。
public actor QueryHistoryStore {
    public static let shared = QueryHistoryStore()

    private static let legacyKey = "DatabaseManager.queryHistory"
    private static let retentionKey = "DatabaseManager.historyRetentionDays"

    private let defaults: UserDefaults
    private let maxEntries: Int
    // C 句柄非 Sendable；所有访问都由 actor 串行化，deinit 需关闭它，故标 nonisolated(unsafe)。
    nonisolated(unsafe) private var db: OpaquePointer?
    /// 保留期（天）；0 表示不限。
    private var retentionDays: Int

    /// - Parameters:
    ///   - databaseURL: store 文件路径；nil 时用 Application Support/Lode/query-history.sqlite。
    ///   - defaults: 迁移来源与保留期持久化所用的 UserDefaults（测试可注入独立 suite）。
    ///   - maxEntries: 非置顶条目的数量上限。
    public init(databaseURL: URL? = nil, defaults: UserDefaults = .standard, maxEntries: Int = 500) {
        self.defaults = defaults
        self.maxEntries = max(1, maxEntries)
        self.retentionDays = max(0, defaults.integer(forKey: Self.retentionKey))
        let url = databaseURL ?? Self.defaultDatabaseURL()
        self.db = Self.bootstrap(url: url, defaults: defaults, maxEntries: self.maxEntries, retentionDays: self.retentionDays)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public

    /// 记录一条 SQL（trim 后非空才写入）。重复的 (sql, config, database) 去重，时间戳刷新，保留原置顶标记。
    public func record(sql: String, configName: String, database: String) {
        guard let db else { return }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !Self.containsSensitiveContent(trimmed) else { return }

        let wasPinned = Self.existingPinned(db, sql: trimmed, configName: configName, database: database)
        Self.exec(db, "DELETE FROM history WHERE \"sql\" = ? AND \"configName\" = ? AND \"database\" = ?",
                  [trimmed, configName, database])
        Self.insert(db, QueryHistoryEntry(sql: trimmed, configName: configName, database: database, pinned: wasPinned))
        Self.prune(db, retentionDays: retentionDays, maxEntries: maxEntries)
    }

    /// 最近 N 条（置顶优先，其余按时间倒序）。
    public func recent(limit: Int) -> [QueryHistoryEntry] {
        guard let db else { return [] }
        let n = max(1, limit)
        return Self.queryEntries(db,
            "SELECT id, \"sql\", \"configName\", \"database\", executedAt, pinned FROM history "
            + "ORDER BY pinned DESC, CAST(executedAt AS REAL) DESC LIMIT \(n)", [])
    }

    /// 全文搜索：按词元前缀匹配（AND），置顶优先、相关度次之。空查询返回全部。
    public func search(_ query: String) -> [QueryHistoryEntry] {
        guard let db else { return [] }
        guard let match = Self.ftsMatchQuery(query) else { return recent(limit: maxEntries) }
        return Self.queryEntries(db,
            "SELECT id, \"sql\", \"configName\", \"database\", executedAt, pinned FROM history "
            + "WHERE history MATCH ? ORDER BY pinned DESC, rank, CAST(executedAt AS REAL) DESC", [match])
    }

    public func delete(id: UUID) {
        guard let db else { return }
        Self.exec(db, "DELETE FROM history WHERE id = ?", [id.uuidString])
    }

    public func clear() {
        guard let db else { return }
        Self.exec(db, "DELETE FROM history", [])
    }

    /// 置顶/取消置顶某条历史。
    public func setPinned(id: UUID, pinned: Bool) {
        guard let db else { return }
        Self.exec(db, "UPDATE history SET pinned = ? WHERE id = ?", [pinned ? "1" : "0", id.uuidString])
    }

    /// 设置保留期（天，0 不限）并立即清理；持久化到 defaults。
    public func setRetentionDays(_ days: Int) {
        retentionDays = max(0, days)
        defaults.set(retentionDays, forKey: Self.retentionKey)
        if let db { Self.prune(db, retentionDays: retentionDays, maxEntries: maxEntries) }
    }

    public func currentRetentionDays() -> Int {
        retentionDays
    }

    /// 当前条目总数（含置顶）。
    public func count() -> Int {
        guard let db else { return 0 }
        return Self.count(db)
    }

    // MARK: - Bootstrap / migration (nonisolated static，供 init 调用)

    private static func bootstrap(url: URL, defaults: UserDefaults, maxEntries: Int, retentionDays: Int) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS history USING fts5(
                "sql", "configName", "database",
                id UNINDEXED, executedAt UNINDEXED, pinned UNINDEXED
            )
            """, [])
        if let data = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data) {
            for entry in legacy where !containsSensitiveContent(entry.sql) {
                insert(db, entry)
            }
            defaults.removeObject(forKey: legacyKey)
        }
        prune(db, retentionDays: retentionDays, maxEntries: maxEntries)
        return db
    }

    private static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Lode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("query-history.sqlite")
    }

    // MARK: - Retention / cap

    private static func prune(_ db: OpaquePointer, retentionDays: Int, maxEntries: Int) {
        if retentionDays > 0 {
            let cutoff = Date().timeIntervalSince1970 - Double(retentionDays) * 86400
            exec(db, "DELETE FROM history WHERE pinned = '0' AND CAST(executedAt AS REAL) < ?", [String(cutoff)])
        }
        // 非置顶条目超出上限时删除最旧的（置顶始终保留）。maxEntries 为内部常量，直接内插安全。
        exec(db, """
            DELETE FROM history WHERE pinned = '0' AND id NOT IN (
                SELECT id FROM history WHERE pinned = '0'
                ORDER BY CAST(executedAt AS REAL) DESC LIMIT \(maxEntries)
            )
            """, [])
    }

    private static func existingPinned(_ db: OpaquePointer, sql: String, configName: String, database: String) -> Bool {
        let rows = queryEntries(db,
            "SELECT id, \"sql\", \"configName\", \"database\", executedAt, pinned FROM history "
            + "WHERE \"sql\" = ? AND \"configName\" = ? AND \"database\" = ? LIMIT 1",
            [sql, configName, database])
        return rows.first?.pinned ?? false
    }

    private static func insert(_ db: OpaquePointer, _ entry: QueryHistoryEntry) {
        exec(db, "INSERT INTO history(id, \"sql\", \"configName\", \"database\", executedAt, pinned) VALUES(?,?,?,?,?,?)",
             [entry.id.uuidString, entry.sql, entry.configName, entry.database,
              String(entry.executedAt.timeIntervalSince1970), entry.pinned ? "1" : "0"])
    }

    private static func count(_ db: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM history", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - SQLite helpers

    private static func exec(_ db: OpaquePointer, _ sql: String, _ params: [String]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(params, to: statement)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
    }

    private static func queryEntries(_ db: OpaquePointer, _ sql: String, _ params: [String]) -> [QueryHistoryEntry] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(params, to: statement)
        var entries: [QueryHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idText)),
                  let sqlText = sqlite3_column_text(statement, 1),
                  let configText = sqlite3_column_text(statement, 2),
                  let databaseText = sqlite3_column_text(statement, 3),
                  let atText = sqlite3_column_text(statement, 4),
                  let pinnedText = sqlite3_column_text(statement, 5) else { continue }
            entries.append(QueryHistoryEntry(
                id: id,
                sql: String(cString: sqlText),
                configName: String(cString: configText),
                database: String(cString: databaseText),
                executedAt: Date(timeIntervalSince1970: Double(String(cString: atText)) ?? 0),
                pinned: String(cString: pinnedText) == "1"
            ))
        }
        return entries
    }

    private static func bindText(_ params: [String], to statement: OpaquePointer?) {
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), param, -1, historySQLiteTransient)
        }
    }

    // MARK: - Search query shaping

    /// 把用户输入整形成 FTS5 MATCH 表达式：按空白拆词，每词转为 `"词"*` 前缀匹配，AND 连接。
    /// 仅保留含字母/数字的词，避免纯标点触发 FTS5 语法错误；无有效词返回 nil（调用方退回全部）。
    static func ftsMatchQuery(_ raw: String) -> String? {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { token in token.contains { $0.isLetter || $0.isNumber } }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " ")
    }

    /// 识别含用户密码操作的语句（保守匹配）。
    private static func containsSensitiveContent(_ sql: String) -> Bool {
        let upper = sql.uppercased()
        let patterns = ["CREATE USER", "ALTER USER", "DROP USER", "SET PASSWORD", "IDENTIFIED BY", "CREATE ROLE", "ALTER ROLE"]
        return patterns.contains { upper.contains($0) }
    }
}