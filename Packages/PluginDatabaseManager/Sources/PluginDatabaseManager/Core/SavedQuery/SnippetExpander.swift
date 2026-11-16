import Foundation

/// 片段占位符：`${name}` 无默认值，`${name:default}` 带默认值。
public struct SnippetPlaceholder: Equatable, Sendable {
    public let name: String
    public let defaultValue: String

    public init(name: String, defaultValue: String) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// 片段占位符展开器。
///
/// 语法：`${name}` 展开为空串，`${name:default}` 展开为 default（首个冒号之后全部为默认值，
/// 允许默认值内含冒号）。`$$` 转义为字面量 `$`，因此 `$${name}` 产出字面量 `${name}`。
/// 未闭合的 `${` 按字面量处理。展开同时给出首个非空默认值的 UTF-16 选区，供编辑器插入后选中。
public enum SnippetExpander {
    /// 展开后的纯文本。
    public static func expand(_ body: String) -> String {
        expansion(body).text
    }

    /// 按出现顺序列出全部占位符（含重复）。
    public static func placeholders(_ body: String) -> [SnippetPlaceholder] {
        let chars = Array(body)
        var result: [SnippetPlaceholder] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "$" {
                i += 2
                continue
            }
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{",
               let close = closingBrace(chars, from: i + 2) {
                result.append(parse(String(chars[(i + 2)..<close])))
                i = close + 1
                continue
            }
            i += 1
        }
        return result
    }

    /// 展开文本 + 首个非空默认值在展开结果中的 UTF-16 选区（无占位符或全空默认值时为 nil）。
    public static func expansion(_ body: String) -> (text: String, firstSelection: NSRange?) {
        let chars = Array(body)
        var out = ""
        var utf16 = 0
        var firstSelection: NSRange?
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "$", i + 1 < chars.count, chars[i + 1] == "$" {
                out.append("$")
                utf16 += 1
                i += 2
                continue
            }
            if ch == "$", i + 1 < chars.count, chars[i + 1] == "{",
               let close = closingBrace(chars, from: i + 2) {
                let placeholder = parse(String(chars[(i + 2)..<close]))
                if firstSelection == nil, !placeholder.defaultValue.isEmpty {
                    firstSelection = NSRange(location: utf16, length: placeholder.defaultValue.utf16.count)
                }
                out.append(placeholder.defaultValue)
                utf16 += placeholder.defaultValue.utf16.count
                i = close + 1
                continue
            }
            out.append(ch)
            utf16 += String(ch).utf16.count
            i += 1
        }
        return (out, firstSelection)
    }

    private static func closingBrace(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "}" { return j }
            j += 1
        }
        return nil
    }

    private static func parse(_ content: String) -> SnippetPlaceholder {
        if let colon = content.firstIndex(of: ":") {
            let name = String(content[content.startIndex..<colon])
            let defaultValue = String(content[content.index(after: colon)...])
            return SnippetPlaceholder(name: name, defaultValue: defaultValue)
        }
        return SnippetPlaceholder(name: content, defaultValue: "")
    }
}