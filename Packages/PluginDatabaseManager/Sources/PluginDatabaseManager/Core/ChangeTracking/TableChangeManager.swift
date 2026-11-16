import Foundation
import Combine

/// 把一个 ``DatabaseValue`` 转成 SQL 字面量（内联、已转义）。
///
/// 采用内联而非参数绑定，是为了在 SQLite/MySQL/PostgreSQL 三种方言下统一生成
/// 可直接 `execute(sql, params: nil)` 的语句。BLOB 按各方言的十六进制字面量输出。
public func sqlLiteral(for value: DatabaseValue, dialect: DatabaseType) -> String {
    switch value {
    case .null:
        return "NULL"
    case .integer(let i):
        return String(i)
    case .double(let d):
        return String(d)
    case .bool(let b):
        return b ? "TRUE" : "FALSE"
    case .string(let s):
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    case .data(let data):
        let hex = data.map { String(format: "%02x", $0) }.joined()
        switch dialect {
        case .sqlite, .mysql:
            return "X'\(hex)'"
        case .postgresql:
            // bytea 的 hex 输入格式（standard_conforming_strings 默认开启）。
            return "'\\x\(hex)'"
        case .redis:
            return "NULL"
        }
    }
}

/// 单元格编辑文本的列类型族（用于类型感知解析）。
public enum CellColumnTypeFamily: Sendable {
    case integer, real, boolean, binary, text, other

    /// 从 catalog 报告的类型名归类（忽略长度/精度修饰符与 unsigned 等后缀）。
    public init(dataType: String) {
        let lowered = dataType.lowercased()
        let base = lowered
            .split(separator: "(").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // MySQL 以 tinyint(1) 表示 BOOLEAN；归为布尔才能把 true/false 绑定为 1/0。
        if base == "tinyint", lowered.contains("(1)") {
            self = .boolean
            return
        }
        switch base {
        case "int", "integer", "smallint", "bigint", "tinyint", "mediumint",
             "int2", "int4", "int8", "serial", "bigserial", "smallserial", "year":
            self = .integer
        case "real", "double", "double precision", "float", "float4", "float8",
             "numeric", "decimal", "dec", "fixed":
            self = .real
        case "bool", "boolean":
            self = .boolean
        case "blob", "binary", "varbinary", "bytea", "tinyblob", "mediumblob",
             "longblob", "bit varying", "bit":
            self = .binary
        case "text", "tinytext", "mediumtext", "longtext", "varchar",
             "character varying", "char", "character", "clob", "uuid", "json",
             "jsonb", "enum", "set", "name":
            self = .text
        default:
            // 日期/时间/几何等：交给数据库解析文本，不做客户端强转。
            self = .other
        }
    }
}

/// 把单元格编辑文本解析为 ``DatabaseValue``（类型感知）。
///
/// 规则：
/// - 显式 `NULL`（忽略大小写）→ null；空文本 → 空字符串，但原值本就是 NULL 时保持 NULL
///   （清空 NULL 单元格不应意外写入空串；显式空串作用于非 NULL 单元格）；
/// - 给定列类型时按类型族解析：整数列 → integer、浮点列 → double、布尔列 → bool、
///   二进制列 → hex（可带 0x 前缀）否则按 UTF-8 字节；文本列恒为 string；
/// - 未给列类型时沿用原值的类型（避免把文本列里的 "123" 误转成整数）；
/// - 既无列类型也无原值时退回启发式（整数/小数/布尔/字符串）。
public func parseEditedCellValue(
    _ text: String,
    columnType: String? = nil,
    original: DatabaseValue? = nil
) -> DatabaseValue {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.uppercased() == "NULL" { return .null }
    if trimmed.isEmpty { return original == .null ? .null : .string("") }

    if let columnType {
        switch CellColumnTypeFamily(dataType: columnType) {
        case .integer:
            if let i = Int(trimmed) { return .integer(i) }
            return .string(trimmed)
        case .real:
            if let d = Double(trimmed) { return .double(d) }
            return .string(trimmed)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "t", "yes", "y", "1": return .bool(true)
            case "false", "f", "no", "n", "0": return .bool(false)
            default: return .string(trimmed)
            }
        case .binary:
            return parseBinaryCellText(trimmed)
        case .text:
            return .string(trimmed)
        case .other:
            return .string(trimmed)
        }
    }

    if let original {
        switch original {
        case .integer:
            if let i = Int(trimmed) { return .integer(i) }
            return .string(trimmed)
        case .double:
            if let d = Double(trimmed) { return .double(d) }
            return .string(trimmed)
        case .bool:
            switch trimmed.lowercased() {
            case "true", "t", "yes", "y", "1": return .bool(true)
            case "false", "f", "no", "n", "0": return .bool(false)
            default: return .string(trimmed)
            }
        case .string:
            return .string(trimmed)
        case .data:
            return parseBinaryCellText(trimmed)
        case .null:
            break
        }
    }

    if let i = Int(trimmed) { return .integer(i) }
    if let d = Double(trimmed) { return .double(d) }
    switch trimmed.lowercased() {
    case "true": return .bool(true)
    case "false": return .bool(false)
    default: return .string(trimmed)
    }
}

/// 二进制单元格文本：纯 hex（偶数长度、可带 0x 前缀/空白）按字节解析，否则按 UTF-8。
func parseBinaryCellText(_ text: String) -> DatabaseValue {
    let stripped = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
    let compact = stripped.filter { !$0.isWhitespace }
    if !compact.isEmpty, compact.count % 2 == 0, compact.allSatisfy({ $0.isHexDigit }) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            if let byte = UInt8(compact[index..<next], radix: 16) {
                bytes.append(byte)
            } else {
                return .data(Data(text.utf8))
            }
            index = next
        }
        return .data(Data(bytes))
    }
    return .data(Data(text.utf8))
}

/// BLOB 单元格进入编辑时的文本表示（hex，便于无损往返）。
public func hexEditText(for data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// 表数据编辑的"变更跟踪队列"：在内存中暂存单元格修改、行新增、行删除，不立即写库。
///
/// 设计要点：
/// - 编辑只改内存，单元格/行高亮提示；
/// - 保存时按 DELETE → INSERT → UPDATE 顺序在事务中执行，并验证 affected rows；
/// - 行定位：有主键按主键；SQLite 无主键按 rowid；其余无主键表按全列 NULL-safe 匹配；
/// - 每行保留编辑时的原始快照，供提交前乐观锁冲突检测；
/// - 撤销/重做用**快照式**栈：每次变更前快照状态，undo/redo 交换当前与快照。
@MainActor
public final class TableChangeManager: ObservableObject {
    /// 单行的待提交更新（含定位方式与原始快照）。
    public struct PendingRowUpdate {
        public let locator: RowLocator
        public let originalRow: [String: DatabaseValue]
        public var columnUpdates: [String: DatabaseValue]
        /// 显式置回数据库默认值的列（提交时生成 `col = DEFAULT`）。
        public var defaultColumns: Set<String> = []
    }

    /// 一条待删除行的定位与原始快照。
    struct DeletedRow {
        let locator: RowLocator
        let originalRow: [String: DatabaseValue]
    }

    /// 一条待新增的行（暂存各列值，未设的列在保存时使用数据库默认值）。
    public struct PendingInsert: Identifiable {
        public let id: UUID
        public var columnValues: [String: DatabaseValue]
    }

    /// 变更全量快照（供 undo/redo）。
    private struct Snapshot {
        let updatesByRow: [String: PendingRowUpdate]
        let pendingInserts: [PendingInsert]
        let deletedRowKeys: Set<String>
        let deletedRows: [String: DeletedRow]
    }

    @Published public private(set) var updatesByRow: [String: PendingRowUpdate] = [:]
    @Published public private(set) var pendingInserts: [PendingInsert] = []
    @Published public private(set) var deletedRowKeys: Set<String> = []
    private var deletedRows: [String: DeletedRow] = [:]

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    public let table: DatabaseObject
    public let schema: TableSchema
    private let pkColumns: [String]
    private let allColumnNames: [String]

    public init(table: DatabaseObject, schema: TableSchema) {
        self.table = table
        self.schema = schema
        self.pkColumns = schema.columns.filter(\.isPrimaryKey).map(\.name)
        self.allColumnNames = schema.columns.map(\.name)
    }

    /// 只要有数据列即可编辑：无主键表改用 rowid（SQLite）或全列匹配定位。
    public var isEditable: Bool { !allColumnNames.isEmpty }
    public var primaryKeyColumnNames: [String] { pkColumns }

    /// 列的 catalog 类型名（供单元格编辑做类型感知解析）。
    public func columnType(of column: String) -> String? {
        schema.columns.first { $0.name == column }?.dataType
    }

    /// 列的枚举取值（MySQL enum / PG enum），供下拉编辑器。
    public func enumValues(of column: String) -> [String]? {
        schema.columns.first { $0.name == column }?.enumValues
    }

    public var hasChanges: Bool {
        !updatesByRow.isEmpty || !pendingInserts.isEmpty || !deletedRowKeys.isEmpty
    }

    /// 已修改的单元格总数（仅 UPDATE，含置回默认值的列）。
    public var changedCellCount: Int {
        updatesByRow.values.reduce(0) { $0 + $1.columnUpdates.count + $1.defaultColumns.count }
    }

    public var pendingInsertCount: Int { pendingInserts.count }
    public var pendingDeleteCount: Int { deletedRowKeys.count }

    /// 全部待提交变更条目数（用于变更条汇总显示）。
    public var totalPendingCount: Int {
        changedCellCount + pendingInsertCount + pendingDeleteCount
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Row identity

    public func rowKey(rowValues: [DatabaseValue], columns: [String]) -> String? {
        if !pkColumns.isEmpty {
            return pkColumns.map { pk -> String in
                let value = value(of: pk, in: rowValues, columns: columns)
                return "\(pk)=\(value.description)"
            }.joined(separator: "|")
        }
        if let id = rowidValue(rowValues: rowValues, columns: columns) {
            return "rowid=\(id)"
        }
        guard !allColumnNames.isEmpty else { return nil }
        return allColumnNames.map { col -> String in
            let value = value(of: col, in: rowValues, columns: columns)
            return "\(col)=\(keyComponent(for: value))"
        }.joined(separator: "|")
    }

    /// SQLite 无主键表浏览时附带 rowid 列；存在则用作物理行定位。
    private func rowidValue(rowValues: [DatabaseValue], columns: [String]) -> Int64? {
        guard let index = columns.firstIndex(of: "rowid"), index < rowValues.count else { return nil }
        if case .integer(let i) = rowValues[index] { return Int64(i) }
        return nil
    }

    /// 全列匹配的行标识分量：BLOB 用 hex，避免「N bytes」描述碰撞。
    private func keyComponent(for value: DatabaseValue) -> String {
        if case .data(let data) = value { return "0x" + hexEditText(for: data) }
        return value.description
    }

    /// 据当前行构造定位方式：主键 → rowid → 全列。
    private func makeLocator(rowValues: [DatabaseValue], columns: [String]) -> RowLocator {
        if !pkColumns.isEmpty {
            return .primaryKey(pkColumns.map { ColumnValue(column: $0, value: value(of: $0, in: rowValues, columns: columns)) })
        }
        if let id = rowidValue(rowValues: rowValues, columns: columns) {
            return .rowid(id)
        }
        return .fullRow(allColumnNames.map { ColumnValue(column: $0, value: value(of: $0, in: rowValues, columns: columns)) })
    }

    /// 编辑发生时的原始数据列快照（不含 rowid 别名）。
    private func originalRowSnapshot(rowValues: [DatabaseValue], columns: [String]) -> [String: DatabaseValue] {
        var snapshot: [String: DatabaseValue] = [:]
        for column in allColumnNames {
            snapshot[column] = value(of: column, in: rowValues, columns: columns)
        }
        return snapshot
    }

    public func isRowDeleted(rowValues: [DatabaseValue], columns: [String]) -> Bool {
        guard let key = rowKey(rowValues: rowValues, columns: columns) else { return false }
        return deletedRowKeys.contains(key)
    }

    public func displayedValue(column: String, rowValues: [DatabaseValue], columns: [String]) -> DatabaseValue {
        if let key = rowKey(rowValues: rowValues, columns: columns),
           let update = updatesByRow[key],
           let staged = update.columnUpdates[column] {
            return staged
        }
        return value(of: column, in: rowValues, columns: columns)
    }

    public func isCellChanged(column: String, rowValues: [DatabaseValue], columns: [String]) -> Bool {
        guard let key = rowKey(rowValues: rowValues, columns: columns) else { return false }
        guard let update = updatesByRow[key] else { return false }
        return update.columnUpdates[column] != nil || update.defaultColumns.contains(column)
    }

    /// 该单元格是否被暂存为「置回数据库默认值」。
    public func isCellDefault(column: String, rowValues: [DatabaseValue], columns: [String]) -> Bool {
        guard let key = rowKey(rowValues: rowValues, columns: columns) else { return false }
        return updatesByRow[key]?.defaultColumns.contains(column) ?? false
    }

    // MARK: - Cell updates

    public func stageCellUpdate(
        column: String,
        newValue: DatabaseValue,
        rowValues: [DatabaseValue],
        columns: [String]
    ) {
        guard let key = rowKey(rowValues: rowValues, columns: columns) else { return }
        // 已删除的行不允许再改单元格
        guard !deletedRowKeys.contains(key) else { return }
        recordUndo()

        let original = value(of: column, in: rowValues, columns: columns)
        if newValue == original {
            if var row = updatesByRow[key] {
                row.columnUpdates.removeValue(forKey: column)
                row.defaultColumns.remove(column)
                if row.columnUpdates.isEmpty && row.defaultColumns.isEmpty {
                    updatesByRow.removeValue(forKey: key)
                } else {
                    updatesByRow[key] = row
                }
            }
            return
        }

        if var existing = updatesByRow[key] {
            existing.columnUpdates[column] = newValue
            existing.defaultColumns.remove(column)
            updatesByRow[key] = existing
        } else {
            updatesByRow[key] = PendingRowUpdate(
                locator: makeLocator(rowValues: rowValues, columns: columns),
                originalRow: originalRowSnapshot(rowValues: rowValues, columns: columns),
                columnUpdates: [column: newValue]
            )
        }
    }

    /// 暂存「置回数据库默认值」：提交时生成 `col = DEFAULT`（MySQL/PG）。
    /// SQLite 不支持 UPDATE 中的 DEFAULT 关键字，由视图模型先解析默认值再按具体值暂存。
    public func stageCellDefault(column: String, rowValues: [DatabaseValue], columns: [String]) {
        guard let key = rowKey(rowValues: rowValues, columns: columns) else { return }
        guard !deletedRowKeys.contains(key) else { return }
        recordUndo()
        if var existing = updatesByRow[key] {
            existing.columnUpdates.removeValue(forKey: column)
            existing.defaultColumns.insert(column)
            updatesByRow[key] = existing
        } else {
            updatesByRow[key] = PendingRowUpdate(
                locator: makeLocator(rowValues: rowValues, columns: columns),
                originalRow: originalRowSnapshot(rowValues: rowValues, columns: columns),
                columnUpdates: [:],
                defaultColumns: [column]
            )
        }
    }

    // MARK: - Inserts

    /// 新增一行（空），返回临时 id。用户随后编辑其各列。
    @discardableResult
    public func addInsert() -> UUID {
        recordUndo()
        let insert = PendingInsert(id: UUID(), columnValues: [:])
        pendingInserts.append(insert)
        return insert.id
    }

    public func setInsertColumn(insertId: UUID, column: String, value: DatabaseValue) {
        guard let index = pendingInserts.firstIndex(where: { $0.id == insertId }) else { return }
        recordUndo()
        pendingInserts[index].columnValues[column] = value
    }

    public func insertDisplayValue(insertId: UUID, column: String) -> DatabaseValue {
        pendingInserts.first(where: { $0.id == insertId })?.columnValues[column] ?? .null
    }

    /// 新增行该列是否未设值（保存时使用数据库默认值）。
    public func insertUsesDefault(insertId: UUID, column: String) -> Bool {
        pendingInserts.first(where: { $0.id == insertId })?.columnValues[column] == nil
    }

    /// 清除新增行某列的暂存值，恢复为「使用数据库默认值」。
    public func clearInsertColumn(insertId: UUID, column: String) {
        guard let index = pendingInserts.firstIndex(where: { $0.id == insertId }) else { return }
        recordUndo()
        pendingInserts[index].columnValues.removeValue(forKey: column)
    }

    public func removeInsert(_ insertId: UUID) {
        recordUndo()
        pendingInserts.removeAll { $0.id == insertId }
    }

    // MARK: - Deletes

    /// 切换某行的删除标记。
    public func toggleRowDeletion(rowValues: [DatabaseValue], columns: [String]) {
        guard let key = rowKey(rowValues: rowValues, columns: columns) else { return }
        recordUndo()
        if deletedRowKeys.contains(key) {
            deletedRowKeys.remove(key)
            deletedRows.removeValue(forKey: key)
        } else {
            deletedRowKeys.insert(key)
            deletedRows[key] = DeletedRow(
                locator: makeLocator(rowValues: rowValues, columns: columns),
                originalRow: originalRowSnapshot(rowValues: rowValues, columns: columns)
            )
            // 删除后该行的单元格更新不再有意义，移除
            updatesByRow.removeValue(forKey: key)
        }
    }

    // MARK: - Undo / Redo

    public func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(snapshot)
    }

    public func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(snapshot)
    }

    public func discardAll() {
        recordUndo()
        updatesByRow.removeAll()
        pendingInserts.removeAll()
        deletedRowKeys.removeAll()
        deletedRows.removeAll()
    }

    /// 丢弃某一行的全部待提交变更（冲突解决时「放弃」该行）。
    public func removeRowChanges(forKey key: String) {
        recordUndo()
        updatesByRow.removeValue(forKey: key)
        deletedRowKeys.remove(key)
        deletedRows.removeValue(forKey: key)
    }

    // MARK: - SQL generation

    /// DELETE → INSERT → UPDATE（顺序便于"删旧行 + 插同主键新行"场景）。
    public func generatedAllStatements(for type: DatabaseType) -> [String] {
        writePlan(for: type).map(\.sql)
    }

    public func generatedUpdateStatements(for type: DatabaseType) -> [String] {
        writePlan(for: type).filter { $0.kind == .update }.map(\.sql)
    }

    /// 全部待提交写操作（DELETE → INSERT → UPDATE），每条附带行定位目标。
    /// 行按 key 排序，保证语句顺序稳定、可与目标一一对应做写验证。
    public func writePlan(for type: DatabaseType) -> [PlannedWrite] {
        var plan: [PlannedWrite] = []
        for key in deletedRowKeys.sorted() {
            guard let deleted = deletedRows[key] else { continue }
            let target = RowTarget(key: key, locator: deleted.locator, originalRow: deleted.originalRow, columnUpdates: [:], isDelete: true)
            let sql = "DELETE FROM \(tableExpr(type)) WHERE \(whereClause(for: deleted.locator, dialect: type));"
            plan.append(PlannedWrite(sql: sql, kind: .delete, target: target))
        }
        for sql in generatedInsertStatements(for: type) {
            plan.append(PlannedWrite(sql: sql, kind: .insert, target: nil))
        }
        for key in updatesByRow.keys.sorted() {
            guard let row = updatesByRow[key] else { continue }
            let target = RowTarget(key: key, locator: row.locator, originalRow: row.originalRow, columnUpdates: row.columnUpdates, isDelete: false)
            var setParts: [(column: String, fragment: String)] = row.columnUpdates.map {
                ($0.key, "\(q($0.key, type)) = \(sqlLiteral(for: $0.value, dialect: type))")
            }
            setParts += row.defaultColumns.map { ($0, "\(q($0, type)) = DEFAULT") }
            let setClause = setParts.sorted { $0.column < $1.column }.map(\.fragment).joined(separator: ", ")
            let sql = "UPDATE \(tableExpr(type)) SET \(setClause) WHERE \(whereClause(for: row.locator, dialect: type));"
            plan.append(PlannedWrite(sql: sql, kind: .update, target: target))
        }
        return plan
    }

    /// 待提交更新/删除行的定位目标（供提交前乐观锁冲突扫描）。
    public var rowTargets: [RowTarget] {
        writePlanTargets()
    }

    private func writePlanTargets() -> [RowTarget] {
        var targets: [RowTarget] = []
        for key in deletedRowKeys.sorted() {
            guard let deleted = deletedRows[key] else { continue }
            targets.append(RowTarget(key: key, locator: deleted.locator, originalRow: deleted.originalRow, columnUpdates: [:], isDelete: true))
        }
        for key in updatesByRow.keys.sorted() {
            guard let row = updatesByRow[key] else { continue }
            targets.append(RowTarget(key: key, locator: row.locator, originalRow: row.originalRow, columnUpdates: row.columnUpdates, isDelete: false))
        }
        return targets
    }

    /// 提交前重读某行当前快照的查询（按定位方式，SELECT 全部数据列）。
    public func reReadStatement(for target: RowTarget, dialect: DatabaseType) -> String {
        "SELECT * FROM \(tableExpr(dialect)) WHERE \(whereClause(for: target.locator, dialect: dialect));"
    }

    private func tableExpr(_ type: DatabaseType) -> String {
        DatabaseViewModel.qualifiedName(for: table, type: type)
    }

    private func q(_ name: String, _ type: DatabaseType) -> String {
        DatabaseViewModel.quoteIdentifier(name, for: type)
    }

    public func generatedInsertStatements(for type: DatabaseType) -> [String] {
        let tableExpr = DatabaseViewModel.qualifiedName(for: table, type: type)
        func q(_ name: String) -> String { DatabaseViewModel.quoteIdentifier(name, for: type) }

        return pendingInserts.map { insert in
            if insert.columnValues.isEmpty {
                // 空行：让数据库填充默认值
                switch type {
                case .sqlite:
                    return "INSERT INTO \(tableExpr) DEFAULT VALUES;"
                case .mysql, .postgresql:
                    return "INSERT INTO \(tableExpr) () VALUES ();"
                case .redis:
                    return ""
                }
            }
            // 按表结构列顺序输出，保证可读性
            let orderedColumns = allColumnNames.filter { insert.columnValues[$0] != nil }
            let cols = orderedColumns.map(q).joined(separator: ", ")
            let vals = orderedColumns.map { sqlLiteral(for: insert.columnValues[$0]!, dialect: type) }.joined(separator: ", ")
            return "INSERT INTO \(tableExpr) (\(cols)) VALUES (\(vals));"
        }
        .filter { !$0.isEmpty }
    }

    public func generatedDeleteStatements(for type: DatabaseType) -> [String] {
        writePlan(for: type).filter { $0.kind == .delete }.map(\.sql)
    }

    // MARK: - Snapshot helpers

    private func currentSnapshot() -> Snapshot {
        Snapshot(updatesByRow: updatesByRow, pendingInserts: pendingInserts, deletedRowKeys: deletedRowKeys, deletedRows: deletedRows)
    }

    private func restore(_ snapshot: Snapshot) {
        updatesByRow = snapshot.updatesByRow
        pendingInserts = snapshot.pendingInserts
        deletedRowKeys = snapshot.deletedRowKeys
        deletedRows = snapshot.deletedRows
    }

    private func recordUndo() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
    }

    // MARK: - Value lookup

    private func value(of column: String, in rowValues: [DatabaseValue], columns: [String]) -> DatabaseValue {
        guard let index = columns.firstIndex(of: column), index < rowValues.count else { return .null }
        return rowValues[index]
    }
}
