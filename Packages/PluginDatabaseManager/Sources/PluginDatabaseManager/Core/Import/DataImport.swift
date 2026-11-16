import Foundation

/// 导入文件格式。
public enum ImportFileFormat: String, Sendable, Equatable {
    case csv
    case json

    /// 按扩展名判定；未知扩展名回退内容嗅探（首个非空白字符为 [ 或 { 视为 JSON）。
    public static func detect(fileName: String, head: String) -> ImportFileFormat {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "csv", "tsv", "txt": return .csv
        case "json", "ndjson", "jsonl": return .json
        default:
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[") || trimmed.hasPrefix("{") ? .json : .csv
        }
    }
}

/// 导入单元格三态：文本 / 显式 NULL（JSON null）/ 未提供（JSON 缺键、CSV 短行）。
public enum ImportCell: Equatable, Sendable {
    case text(String)
    case null
    case missing
}

/// 推断/目标列类型。
public enum ImportColumnType: String, Sendable, Equatable, CaseIterable {
    case integer
    case double
    case boolean
    case text

    /// 由 SQL 类型名粗分类（用于导入现有表时按目标列转换）。按首段单词匹配，避免 interval/point 误判。
    public static func from(sqlType: String) -> ImportColumnType {
        let base = sqlType.lowercased().prefix(while: { $0.isLetter })
        switch base {
        case "int", "integer", "bigint", "smallint", "tinyint", "mediumint", "serial", "bigserial", "smallserial":
            return .integer
        case "bool", "boolean":
            return .boolean
        case "double", "float", "float4", "float8", "real", "numeric", "decimal", "dec":
            return .double
        default:
            return .text
        }
    }

    /// 建新表草稿时的建表类型（跨引擎通用写法）。
    public var createTableType: String {
        switch self {
        case .integer: return "INTEGER"
        case .double: return "REAL"
        case .boolean: return "BOOLEAN"
        case .text: return "TEXT"
        }
    }
}

/// 源列 → 目标列映射（targetColumn 为 nil 表示跳过该源列）。
public struct ImportColumnMapping: Equatable, Sendable {
    public var sourceColumn: String
    public var targetColumn: String?
    public var inferredType: ImportColumnType

    public init(sourceColumn: String, targetColumn: String?, inferredType: ImportColumnType) {
        self.sourceColumn = sourceColumn
        self.targetColumn = targetColumn
        self.inferredType = inferredType
    }
}

/// 坏行记录（行号为数据行序号，从 1 起，不含表头）。
public struct ImportBadRow: Equatable, Sendable {
    public let rowNumber: Int
    public let message: String

    public init(rowNumber: Int, message: String) {
        self.rowNumber = rowNumber
        self.message = message
    }
}

/// 坏行策略：跳过继续 / 立即中止。
public enum ImportBadRowStrategy: String, Sendable, Equatable, CaseIterable {
    case skip
    case abort
}

public enum ImportError: Error, Equatable, LocalizedError {
    case emptyFile
    case noColumns
    case noMappedColumns
    case duplicateTargetColumn(String)
    case conversionFailed(column: String, value: String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile: return "The file contains no data rows."
        case .noColumns: return "No columns could be determined from the file."
        case .noMappedColumns: return "Map at least one source column to a target column."
        case .duplicateTargetColumn(let name): return "Target column \"\(name)\" is mapped more than once."
        case .conversionFailed(let column, let value): return "Row value \"\(value)\" is not valid for column \"\(column)\"."
        case .invalidJSON(let detail): return "The JSON file could not be parsed: \(detail)"
        }
    }
}

/// 从采样值推断列类型：全整数 → integer，全有限小数 → double，全 true/false → boolean，否则 text。
/// 空串不参与判定；无有效样本回退 text。
public enum ImportTypeInference {
    public static func infer(_ samples: [String]) -> ImportColumnType {
        let values = samples.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return .text }
        if values.allSatisfy({ Int($0) != nil }) { return .integer }
        if values.allSatisfy({ isFiniteDouble($0) }) { return .double }
        if values.allSatisfy({ ["true", "false"].contains($0.lowercased()) }) { return .boolean }
        return .text
    }

    private static func isFiniteDouble(_ s: String) -> Bool {
        guard let d = Double(s) else { return false }
        return d.isFinite
    }
}

/// 单元格 → 绑定参数。转换失败抛 ImportError.conversionFailed（由管线记为坏行）。
public enum ImportValueConverter {
    public static func databaseValue(
        _ cell: ImportCell,
        as type: ImportColumnType,
        column: String,
        emptyAsNull: Bool
    ) throws -> DatabaseValue {
        switch cell {
        case .null, .missing:
            return .null
        case .text(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return emptyAsNull ? .null : .string(raw) }
            switch type {
            case .integer:
                guard let i = Int(trimmed) else { throw ImportError.conversionFailed(column: column, value: raw) }
                return .integer(i)
            case .double:
                guard let d = Double(trimmed), d.isFinite else { throw ImportError.conversionFailed(column: column, value: raw) }
                return .double(d)
            case .boolean:
                switch trimmed.lowercased() {
                case "true", "yes", "t", "1": return .bool(true)
                case "false", "no", "f", "0": return .bool(false)
                default: throw ImportError.conversionFailed(column: column, value: raw)
                }
            case .text:
                return .string(raw)
            }
        }
    }
}

/// 列映射：按名对齐（大小写不敏感）+ 采样推断；未匹配源列默认跳过。
public enum ImportMappingBuilder {
    public static func autoMap(
        sourceColumns: [String],
        targetColumns: [String],
        samples: [[String]]
    ) -> [ImportColumnMapping] {
        let loweredTargets = targetColumns.map { $0.lowercased() }
        return sourceColumns.enumerated().map { index, source in
            let match = loweredTargets.firstIndex(of: source.lowercased()).map { targetColumns[$0] }
            let columnSamples = samples.compactMap { row -> String? in
                guard index < row.count else { return nil }
                return row[index]
            }
            return ImportColumnMapping(
                sourceColumn: source,
                targetColumn: match,
                inferredType: ImportTypeInference.infer(columnSamples)
            )
        }
    }

    public static func validate(_ mappings: [ImportColumnMapping]) throws {
        var seen = Set<String>()
        var mapped = 0
        for mapping in mappings {
            guard let target = mapping.targetColumn, !target.isEmpty else { continue }
            mapped += 1
            let key = target.lowercased()
            guard seen.insert(key).inserted else { throw ImportError.duplicateTargetColumn(target) }
        }
        guard mapped > 0 else { throw ImportError.noMappedColumns }
    }

    /// 由映射生成建新表草稿：仅纳入已映射源列，类型取推断值，全部可空（导入数据可能含 NULL）。
    public static func newTableDraft(name: String, mappings: [ImportColumnMapping]) -> NewTableDraft {
        let columns = mappings.compactMap { mapping -> NewTableColumnDraft? in
            guard let target = mapping.targetColumn, !target.isEmpty else { return nil }
            return NewTableColumnDraft(name: target, dataType: mapping.inferredType.createTableType, isNullable: true)
        }
        return NewTableDraft(name: name, columns: columns)
    }
}

/// 导入目标：现有表（按目标列类型转换）或建新表（按推断类型，经建表管线）。
public enum ImportTarget: Equatable, Sendable {
    case existingTable(DatabaseObject)
    case newTable(NewTableDraft)
}

/// 导入选项：空串按 NULL、坏行策略、批大小（按列数钳制占位符上限）。
public struct ImportOptions: Equatable, Sendable {
    public var emptyAsNull: Bool
    public var badRowStrategy: ImportBadRowStrategy
    public var batchSize: Int

    public init(emptyAsNull: Bool = true, badRowStrategy: ImportBadRowStrategy = .skip, batchSize: Int = 500) {
        self.emptyAsNull = emptyAsNull
        self.badRowStrategy = badRowStrategy
        self.batchSize = batchSize
    }
}

/// 批量参数化 INSERT 语句：多行 VALUES 占位符（PG $1…$n，MySQL/SQLite ?），参数按行优先展平。
public enum ImportSQLBuilder {
    public static func insertStatement(
        table: DatabaseObject,
        columns: [String],
        rowCount: Int,
        type: DatabaseType
    ) -> String {
        let tableExpr = DatabaseViewModel.qualifiedName(for: table, type: type)
        let cols = columns.map { DatabaseViewModel.quoteIdentifier($0, for: type) }.joined(separator: ", ")
        var placeholders: [String] = []
        var index = 0
        for _ in 0..<rowCount {
            let row = columns.map { _ -> String in
                index += 1
                return type == .postgresql ? "$\(index)" : "?"
            }
            placeholders.append("(\(row.joined(separator: ", ")))")
        }
        return "INSERT INTO \(tableExpr) (\(cols)) VALUES \(placeholders.joined(separator: ", "))"
    }
}