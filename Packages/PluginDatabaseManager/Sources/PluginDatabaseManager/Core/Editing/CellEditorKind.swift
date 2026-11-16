import Foundation

/// 单元格按列类型路由到的编辑器种类。
public enum CellEditorKind: Sendable, Equatable {
    case text
    case integer
    case decimal
    case boolean
    case date
    case dateTime
    case time
    case enumeration([String])
    case json
    case binary
}

/// 据 catalog 类型名（忽略长度/精度修饰符）路由编辑器。
///
/// - 已知枚举取值（MySQL enum / PG enum）优先路由下拉；
/// - PG 数组类型（`integer[]` 或内部名 `_int4`）按文本字面量编辑（`{1,2,3}`）；
/// - 日期/时间族按名称细分；JSON 族带校验；其余沿用 ``CellColumnTypeFamily``。
public func cellEditorKind(for dataType: String, enumValues: [String]? = nil) -> CellEditorKind {
    if let enumValues, !enumValues.isEmpty { return .enumeration(enumValues) }
    let lowered = dataType.lowercased().trimmingCharacters(in: .whitespaces)
    let base = lowered.split(separator: "(").first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    if lowered.hasSuffix("[]") || base.hasPrefix("_") { return .text }
    switch base {
    case "date":
        return .date
    case "datetime", "timestamp", "timestamptz",
         "timestamp without time zone", "timestamp with time zone":
        return .dateTime
    case "time", "timetz", "time without time zone", "time with time zone":
        return .time
    case "json", "jsonb":
        return .json
    default:
        break
    }
    switch CellColumnTypeFamily(dataType: dataType) {
    case .integer: return .integer
    case .real: return .decimal
    case .boolean: return .boolean
    case .binary: return .binary
    case .text, .other: return .text
    }
}

/// 解析 MySQL `column_type` 中的 enum 取值列表（`enum('a','b')`）。
///
/// 值内单引号按 SQL 规则以 `''` 转义（兼容 `\'`）；非 enum 类型返回 nil。
public func mysqlEnumValues(in columnType: String) -> [String]? {
    let lowered = columnType.lowercased()
    guard lowered.hasPrefix("enum("), lowered.hasSuffix(")") else { return nil }
    let inner = Array(columnType.dropFirst(5).dropLast())
    var values: [String] = []
    var current = ""
    var inQuote = false
    var i = 0
    while i < inner.count {
        let ch = inner[i]
        if !inQuote {
            if ch == "'" { inQuote = true; current = "" }
        } else if ch == "'" {
            if i + 1 < inner.count, inner[i + 1] == "'" {
                current.append("'")
                i += 1
            } else {
                inQuote = false
                values.append(current)
            }
        } else if ch == "\\", i + 1 < inner.count {
            current.append(inner[i + 1])
            i += 1
        } else {
            current.append(ch)
        }
        i += 1
    }
    return values.isEmpty ? nil : values
}

// MARK: - 日期/时间文本与 Date 的互转

/// 日期时间单元格文本的固定格式（按编辑器种类尝试，全部 UTC，保证往返稳定）。
private func cellDateFormats(for kind: CellEditorKind) -> [String] {
    switch kind {
    case .date:
        return ["yyyy-MM-dd"]
    case .dateTime:
        return ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"]
    case .time:
        return ["HH:mm:ss", "HH:mm"]
    default:
        return []
    }
}

private func cellDateFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format
    return formatter
}

/// 把单元格文本解析为 Date（仅日期/时间族编辑器；无法解析返回 nil）。
///
/// 小数秒手动解析：DateFormatter 的 `S` 只保留毫秒精度，会吞掉微秒；
/// 驱动对 timestamptz 统一以 UTC 输出并附 `+00` 后缀，解析时剥掉。
public func parseCellDate(_ text: String, kind: CellEditorKind) -> Date? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var fraction: TimeInterval = 0
    if kind == .dateTime || kind == .time {
        if kind == .dateTime, trimmed.hasSuffix("+00") {
            trimmed = String(trimmed.dropLast(3))
        }
        if let dot = trimmed.lastIndex(of: ".") {
            let digits = trimmed[trimmed.index(after: dot)...]
            guard !digits.isEmpty, digits.count <= 6,
                  digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            fraction = Double("0." + digits) ?? 0
            trimmed = String(trimmed[..<dot])
        }
    }
    for format in cellDateFormats(for: kind) {
        if let date = cellDateFormatter(format).date(from: trimmed) {
            return date.addingTimeInterval(fraction)
        }
    }
    return nil
}

/// 把 Date 格式化为单元格提交文本（日期族用 `yyyy-MM-dd`，日期时间族用
/// `yyyy-MM-dd HH:mm:ss`，时间族用 `HH:mm:ss`；其他种类返回 nil）。
public func formatCellDate(_ date: Date, kind: CellEditorKind) -> String? {
    guard let format = cellDateFormats(for: kind).first else { return nil }
    return cellDateFormatter(format).string(from: date)
}

// MARK: - JSON 校验

/// 文本是否为合法 JSON（允许标量片段：MySQL/PG 的 JSON 列均接受顶层标量）。
public func isValidJSONText(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])) != nil
}