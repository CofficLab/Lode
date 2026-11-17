import Foundation

/// 连接级 Agent 访问控制：允许列表（默认允许，可逐连接禁用）+ 会话活跃连接跟踪。
///
/// 同步读（NSLock）——工具风险分级 `permissionRiskLevel` 是同步契约，不能 await。
/// 禁用某连接后，Agent 工具既看不到它（listConnections 过滤），也无法访问它
/// （describe/query/sample 在取配置时拒绝）。
public final class DatabaseAgentAccessPolicy: @unchecked Sendable {
    public static let shared = DatabaseAgentAccessPolicy()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private var blocked: Set<UUID>
    private var activeId: UUID?

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "DatabaseAgentAccessPolicy.blockedConnections"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        let raw = defaults.stringArray(forKey: storageKey) ?? []
        self.blocked = Set(raw.compactMap(UUID.init(uuidString:)))
    }

    public func isAllowed(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !blocked.contains(id)
    }

    public func setAllowed(_ allowed: Bool, for id: UUID) {
        lock.lock()
        if allowed {
            blocked.remove(id)
        } else {
            blocked.insert(id)
        }
        let snapshot = blocked.map(\.uuidString)
        lock.unlock()
        defaults.set(snapshot, forKey: storageKey)
    }

    /// 当前工作区激活的连接；未连接任何库时为 nil。
    public var activeConnectionId: UUID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return activeId
        }
        set {
            lock.lock()
            activeId = newValue
            lock.unlock()
        }
    }

    /// 访问非激活连接视为跨连接访问，需要用户审批。
    public func isCrossConnection(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeId != nil && activeId != id
    }

    /// 敏感表启发式：对大小写不敏感的表名做保守子串匹配。
    /// 误报只会多一次审批提示，不会放行真正的敏感表。
    public static func isSensitiveTableName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let markers = [
            "password", "passwd", "secret", "token", "credential",
            "api_key", "apikey", "private_key", "privatekey",
            "credit_card", "creditcard", "payment", "ssn",
        ]
        return markers.contains { lower.contains($0) }
    }
}

/// Agent 工具审计条目：谁（哪个工具）在哪个连接执行了什么、结果如何。
/// detail 写入前截断并脱敏，绝不携带密码/密钥。
public struct DatabaseAgentAuditEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let tool: String
    public let connectionId: String?
    public let connectionName: String?
    public let detail: String
    public let outcome: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        tool: String,
        connectionId: String?,
        connectionName: String?,
        detail: String,
        outcome: String
    ) {
        self.id = id
        self.date = date
        self.tool = tool
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.detail = detail
        self.outcome = outcome
    }
}

/// 滚动审计日志：最近 ``maxEntries`` 条，持久化到 UserDefaults，设置面板可查看/清空。
public final class DatabaseAgentAuditLog: @unchecked Sendable {
    public static let shared = DatabaseAgentAuditLog()
    public static let maxEntries = 200
    public static let maxDetailLength = 200

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private var entries: [DatabaseAgentAuditEntry]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "DatabaseAgentAuditLog.entries"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([DatabaseAgentAuditEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    public func record(
        tool: String,
        connectionId: String?,
        connectionName: String?,
        detail: String,
        outcome: String
    ) {
        // 先脱敏再截断：替换标记可能比原值长，截断在后才能保证长度上限。
        let redacted = LogRedactor.redact(detail)
        let trimmed = redacted.count > Self.maxDetailLength
            ? String(redacted.prefix(Self.maxDetailLength)) + "…"
            : redacted
        let entry = DatabaseAgentAuditEntry(
            tool: tool,
            connectionId: connectionId,
            connectionName: connectionName,
            detail: trimmed,
            outcome: outcome
        )
        lock.lock()
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        let snapshot = entries
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// 最新在前。
    public func recent() -> [DatabaseAgentAuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed()
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        defaults.removeObject(forKey: storageKey)
    }
}