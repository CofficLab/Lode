import Foundation

/// JSON 导入解析：对象数组 / 单个对象 / NDJSON（每行一个对象）/ 标量数组的数组。
/// 列名为全部对象键的首次出现顺序（稳定）；缺键 → missing，null → null，
/// 嵌套对象/数组序列化为紧凑 JSON 文本。布尔按 CFBoolean 类型区分（NSNumber as? Bool 对 0/1 也成立）。
public enum JSONImportParser {
    public static func parse(_ text: String) throws -> (columns: [String], rows: [[ImportCell]]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyFile }
        if let whole = parseWholeJSON(trimmed) {
            return whole
        }
        if let ndjson = parseNDJSON(trimmed) {
            return ndjson
        }
        throw ImportError.invalidJSON("expected an array of objects, a single object, or one object per line")
    }

    private static func parseWholeJSON(_ text: String) -> (columns: [String], rows: [[ImportCell]])? {
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
            var columns: [String] = []
            var seen = Set<String>()
            for item in objects {
                for key in item.keys.sorted() where seen.insert(key).inserted {
                    columns.append(key)
                }
            }
            let rows = objects.map { item in columns.map { key in item[key].map(jsonCell) ?? .missing } }
            return (columns, rows)
        }
        if let arrays = items as? [[Any]] {
            let width = arrays.map(\.count).max() ?? 0
            guard width > 0 else { return nil }
            let columns = (1...width).map { "Column \($0)" }
            let rows = arrays.map { row in
                columns.indices.map { index in index < row.count ? jsonCell(row[index]) : .missing }
            }
            return (columns, rows)
        }
        return nil
    }

    private static func parseNDJSON(_ text: String) -> (columns: [String], rows: [[ImportCell]])? {
        var objects: [[String: Any]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            guard trimmedLine.hasPrefix("{"),
                  let data = trimmedLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            objects.append(object)
        }
        guard !objects.isEmpty else { return nil }
        var columns: [String] = []
        var seen = Set<String>()
        for item in objects {
            for key in item.keys.sorted() where seen.insert(key).inserted {
                columns.append(key)
            }
        }
        let rows = objects.map { item in columns.map { key in item[key].map(jsonCell) ?? .missing } }
        return (columns, rows)
    }

    private static func jsonCell(_ value: Any) -> ImportCell {
        if value is NSNull { return .null }
        if let s = value as? String { return .text(s) }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .text(n.boolValue ? "true" : "false") }
            return .text(n.stringValue)
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return .text(s)
        }
        return .text(String(describing: value))
    }
}