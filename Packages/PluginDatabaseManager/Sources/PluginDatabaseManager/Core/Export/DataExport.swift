import Foundation

/// 导出文件格式。
public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case csv
    case json
    case sqlInsert
    case markdown

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .sqlInsert: return "sql"
        case .markdown: return "md"
        }
    }
}

/// 导出行范围：当前页 / 全部行（流式分页）/ 当前筛选结果。
public enum ExportRowRange: String, CaseIterable, Codable, Sendable {
    case currentPage
    case allRows
    case filteredRows
}

/// 导出预设（格式 + 行范围），持久化为 JSON 数组。
public struct ExportPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var format: ExportFormat
    public var range: ExportRowRange

    public init(id: UUID = UUID(), name: String, format: ExportFormat, range: ExportRowRange) {
        self.id = id
        self.name = name
        self.format = format
        self.range = range
    }
}

/// 流式导出写入器：逐行产出文本片段（header/row/footer），由调用方增量写盘，
/// 任意行数都不整载。值语义与网格复制一致（``GridCopyFormat``）：
/// CSV NULL→空字段、BLOB→0x hex；JSON 类型化值、BLOB→0x hex 文本；SQL 走方言字面量转义。
public enum DataExportWriter {
    /// 文件头：CSV 表头行 / JSON "[" / Markdown 表头+分隔行 / SQL 无。
    public static func header(format: ExportFormat, columns: [String]) -> String? {
        switch format {
        case .csv:
            return GridCopyFormat.csvWithHeaders(columns: columns, rows: []) + "\r\n"
        case .json:
            return "[\n"
        case .sqlInsert:
            return nil
        case .markdown:
            return GridCopyFormat.markdownTable(columns: columns, rows: []) + "\n"
        }
    }

    /// 单行文本（含行尾）。JSON 非首行前置逗号分隔；SQL 需要已限定引号化的表名。
    public static func row(
        format: ExportFormat,
        columns: [String],
        row: [DatabaseValue],
        tableExpr: String,
        dialect: DatabaseType,
        isFirst: Bool
    ) -> String {
        switch format {
        case .csv:
            return GridCopyFormat.rowCSV(columns: columns, row: row) + "\r\n"
        case .json:
            return (isFirst ? "" : ",\n") + GridCopyFormat.rowJSON(columns: columns, row: row)
        case .sqlInsert:
            return GridCopyFormat.insertSQL(tableExpr: tableExpr, columns: columns, row: row, dialect: dialect) + "\n"
        case .markdown:
            return GridCopyFormat.rowMarkdown(columns: columns, row: row) + "\n"
        }
    }

    /// 文件尾：JSON "]"，其余无。
    public static func footer(format: ExportFormat) -> String? {
        format == .json ? "\n]\n" : nil
    }
}