import Foundation

/// 粘贴单元格三态：文本 / 显式 NULL / 未提供（保留数据库默认值）。
public enum GridPasteCell: Equatable, Sendable {
    case text(String)
    case null
    case unset
}

/// 剪贴板行粘贴解析：CSV / JSON → 与网格列对齐的单元格矩阵。
///
/// - CSV：RFC 4180；首行字段若全为网格列名（大小写不敏感、不重复、允许列子集）
///   则视为表头（按名映射、可乱序），否则按位置映射；空字段按空串处理
///   （CSV 无 NULL 约定），缺少的尾部字段保留默认值。
/// - JSON：对象数组按列名映射（null → NULL，缺键 → 保留默认值）；单个对象视为一行；
///   数组的数组按位置映射。
/// 无法解析返回 nil。
public enum GridPasteParser {
    public static func parse(_ text: String, columns: [String]) -> [[GridPasteCell]]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !columns.isEmpty else { return nil }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return parseJSON(trimmed, columns: columns)
        }
        return parseCSVRows(trimmed, columns: columns)
    }

    // MARK: - CSV

    /// RFC 4180 状态机：引号内逗号/换行为字面量，`""` 为引号转义。
    public static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        // 按 Unicode 标量迭代：Swift 的 Character 把 CRLF 视为单个字素，
        // 逐 Character 匹配会漏掉 \r\n 行尾。
        let chars = Array(text.unicodeScalars)
        var i = 0
        func endField() {
            row.append(field)
            field = ""
            fieldStarted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.append(String(ch))
                i += 1
                continue
            }
            switch ch {
            case "\"" where !fieldStarted:
                inQuotes = true
                fieldStarted = true
            case ",":
                endField()
            case "\r":
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRow()
            case "\n":
                endRow()
            default:
                field.append(String(ch))
                fieldStarted = true
            }
            i += 1
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty {
            endRow()
        }
        // 末尾空行（仅一个空字段）不视为数据行。
        if let last = rows.last, last.count == 1, last[0].isEmpty, rows.count > 1 {
            rows.removeLast()
        }
        return rows
    }

    private static func parseCSVRows(_ text: String, columns: [String]) -> [[GridPasteCell]]? {
        let raw = parseCSV(text)
        guard !raw.isEmpty else { return nil }
        let lowered = columns.map { $0.lowercased() }
        let firstLowered = raw[0].map { $0.lowercased() }
        let firstSet = Set(firstLowered)
        let hasHeader = !firstLowered.isEmpty
            && firstSet.count == firstLowered.count
            && firstSet.isSubset(of: Set(lowered))
        let dataRows = hasHeader ? Array(raw.dropFirst()) : raw
        guard !dataRows.isEmpty else { return nil }
        if hasHeader {
            let order = columns.map { name in firstLowered.firstIndex(of: name.lowercased()) ?? -1 }
            return dataRows.map { row in
                order.map { sourceIndex in
                    sourceIndex >= 0 && sourceIndex < row.count ? .text(row[sourceIndex]) : .unset
                }
            }
        }
        return dataRows.map { row in
            columns.indices.map { index in index < row.count ? .text(row[index]) : .unset }
        }
    }

    // MARK: - JSON

    private static func parseJSON(_ text: String, columns: [String]) -> [[GridPasteCell]]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else { return nil }
        let items: [Any]
        if let array = object as? [Any] {
            items = array
        } else if object is [String: Any] {
            items = [object]
        } else {
            return nil
        }
        guard !items.isEmpty else { return nil }
        if let objects = items as? [[String: Any]] {
            return objects.map { item in
                columns.map { column in
                    guard let value = item[column] else { return .unset }
                    return jsonCell(value)
                }
            }
        }
        if let arrays = items as? [[Any]] {
            return arrays.map { row in
                columns.indices.map { index in index < row.count ? jsonCell(row[index]) : .unset }
            }
        }
        return nil
    }

    private static func jsonCell(_ value: Any) -> GridPasteCell {
        if value is NSNull { return .null }
        if let s = value as? String { return .text(s) }
        if let n = value as? NSNumber {
            // NSNumber 的 as? Bool 对 0/1 也成立，须按 CFBoolean 类型区分真假布尔。
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .text(n.boolValue ? "true" : "false") }
            return .text(n.stringValue)
        }
        return .text(String(describing: value))
    }
}