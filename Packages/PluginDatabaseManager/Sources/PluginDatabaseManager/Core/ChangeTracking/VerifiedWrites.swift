import Foundation

/// 一个列名/值对（用于行定位与全列匹配）。
public struct ColumnValue: Sendable, Equatable {
    public let column: String
    public let value: DatabaseValue

    public init(column: String, value: DatabaseValue) {
        self.column = column
        self.value = value
    }
}

/// 行定位方式：决定 UPDATE/DELETE 的 WHERE 子句与提交前重读快照的查询。
///
/// - ``primaryKey``：有主键的表，按主键值定位（内容改动后仍可稳定命中）。
/// - ``rowid``：SQLite 无主键表，按物理 rowid 定位（可区分完全相同的重复行）。
/// - ``fullRow``：MySQL/PostgreSQL 无主键表，按全部列的原始值 NULL-safe 匹配定位。
public enum RowLocator: Sendable, Equatable {
    case primaryKey([ColumnValue])
    case rowid(Int64)
    case fullRow([ColumnValue])
}

/// 一个待写入行的定位与原始快照（供乐观锁冲突检测与写验证）。
public struct RowTarget: Sendable {
    /// 变更队列内的行标识（与 ``TableChangeManager/rowKey(rowValues:columns:)`` 一致）。
    public let key: String
    public let locator: RowLocator
    /// 编辑发生时该行的原始列值（仅数据列，不含 rowid 别名）。
    public let originalRow: [String: DatabaseValue]
    /// 暂存的单元格更新（删除行为空）。
    public let columnUpdates: [String: DatabaseValue]
    public let isDelete: Bool

    public init(
        key: String,
        locator: RowLocator,
        originalRow: [String: DatabaseValue],
        columnUpdates: [String: DatabaseValue],
        isDelete: Bool
    ) {
        self.key = key
        self.locator = locator
        self.originalRow = originalRow
        self.columnUpdates = columnUpdates
        self.isDelete = isDelete
    }
}

/// 待提交写操作的类型。
public enum WriteKind: Sendable, Equatable {
    case delete, insert, update
}

/// 一条已生成 SQL 的待提交写操作，附带定位目标（INSERT 无目标）。
public struct PlannedWrite: Sendable {
    public let sql: String
    public let kind: WriteKind
    public let target: RowTarget?

    public init(sql: String, kind: WriteKind, target: RowTarget?) {
        self.sql = sql
        self.kind = kind
        self.target = target
    }
}

/// 乐观锁冲突的类型。
public enum RowConflictKind: Sendable, Equatable {
    /// 行仍在，但他人改动了内容（按主键/rowid 重读后与原始快照不一致）。
    case changed
    /// 行已不存在，或无主键表的全列匹配不再命中（内容被改/行被删）。
    case missing
    /// 定位命中多行（无主键表存在重复行），无法确定唯一目标。
    case ambiguous
}

/// 提交前检测到的一处行冲突。
public struct RowConflict: Sendable, Identifiable {
    public let id: String
    public let target: RowTarget
    public let kind: RowConflictKind
    /// 重读到的当前行（missing/ambiguous 时为 nil）。
    public let currentRow: [String: DatabaseValue]?
    /// 与原始快照不一致的列（按列名排序，便于稳定展示）。
    public let changedColumns: [String]

    public init(
        id: String,
        target: RowTarget,
        kind: RowConflictKind,
        currentRow: [String: DatabaseValue]?,
        changedColumns: [String]
    ) {
        self.id = id
        self.target = target
        self.kind = kind
        self.currentRow = currentRow
        self.changedColumns = changedColumns
    }
}

/// 写操作类别（用于 affected rows 验证的方言语义）。
public enum WriteOperation: Sendable, Equatable {
    case update, delete
}

/// 写验证失败：affected rows 与预期不符，或定位命中数不为 1。
public struct WriteVerificationError: Error, LocalizedError, Sendable {
    public enum Reason: Sendable, Equatable {
        case affectedMismatch
        case missingRow
        case ambiguousRow
    }

    public let sql: String
    public let expected: Int
    public let actual: Int
    public let reason: Reason

    public init(sql: String, expected: Int, actual: Int, reason: Reason) {
        self.sql = sql
        self.expected = expected
        self.actual = actual
        self.reason = reason
    }

    public var errorDescription: String? {
        switch reason {
        case .missingRow:
            return "Write aborted: the target row no longer exists (it was changed or deleted by another client). Statement: \(sql)"
        case .ambiguousRow:
            return "Write aborted: the row locator matched \(actual) rows instead of 1 (duplicate rows in a table without a primary key). Statement: \(sql)"
        case .affectedMismatch:
            return "Write aborted: expected \(expected) affected row but got \(actual). Statement: \(sql)"
        }
    }
}

/// 按方言生成行定位的 WHERE 子句（NULL-safe：NULL 列用 `IS NULL`）。
public func whereClause(for locator: RowLocator, dialect: DatabaseType) -> String {
    func q(_ name: String) -> String { DatabaseViewModel.quoteIdentifier(name, for: dialect) }
    switch locator {
    case .primaryKey(let pairs), .fullRow(let pairs):
        return pairs.map { pair in
            if pair.value == .null { return "\(q(pair.column)) IS NULL" }
            return "\(q(pair.column)) = \(sqlLiteral(for: pair.value, dialect: dialect))"
        }.joined(separator: " AND ")
    case .rowid(let id):
        return "rowid = \(id)"
    }
}

/// 验证一条 UPDATE/DELETE 的 affected rows 是否恰好命中一行。
///
/// 跨引擎语义差异：MySQL 默认报告「实际改变」的行数（值未变时为 0），
/// PostgreSQL/SQLite 报告「匹配」的行数。因此 UPDATE 在 MySQL 上允许 0
/// （提交前重读已证明定位恰好命中一行，值相同视为无操作）；DELETE 恒要求 1。
/// 任何引擎上 affected > 1 都视为定位歧义，立即中止。
public func verifyAffectedRows(actual: Int, operation: WriteOperation, dialect: DatabaseType, sql: String = "") throws {
    if actual > 1 {
        throw WriteVerificationError(sql: sql, expected: 1, actual: actual, reason: .ambiguousRow)
    }
    if actual == 1 { return }
    // actual == 0
    if operation == .update && dialect == .mysql { return }
    throw WriteVerificationError(sql: sql, expected: 1, actual: actual, reason: .affectedMismatch)
}

/// 把重读结果与原始快照比对，检测乐观锁冲突；无冲突返回 nil。
public func detectRowConflict(target: RowTarget, result: QueryResult) -> RowConflict? {
    if result.rows.isEmpty {
        return RowConflict(id: target.key, target: target, kind: .missing, currentRow: nil, changedColumns: [])
    }
    if result.rows.count > 1 {
        return RowConflict(id: target.key, target: target, kind: .ambiguous, currentRow: nil, changedColumns: [])
    }
    let row = result.rows[0]
    var current: [String: DatabaseValue] = [:]
    for (index, column) in result.columns.enumerated() where index < row.count {
        current[column] = row[index]
    }
    var changed: [String] = []
    for (column, original) in target.originalRow {
        let currentValue = current[column] ?? .null
        if currentValue != original { changed.append(column) }
    }
    if changed.isEmpty { return nil }
    return RowConflict(
        id: target.key,
        target: target,
        kind: .changed,
        currentRow: current,
        changedColumns: changed.sorted()
    )
}