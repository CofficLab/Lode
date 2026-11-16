import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-4 本地化审计回归：目录源语言为英文；代码中每个 pluginLocalization.string("…")
// 引用的键都存在于目录且五语言（en/zh-HK/zh-Hans/zh-Hant/zh-TW）均已翻译非空；
// 本次审计补全的键带正确简体中文译文。路径由 #file 动态推导，不硬编码本机路径。

@Suite(.serialized)
struct LocalizationCatalogTests {
    private static let locales = ["en", "zh-HK", "zh-Hans", "zh-Hant", "zh-TW"]

    private var packageRoot: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // PluginDatabaseManager/
    }

    private func catalogStrings() throws -> [String: Any] {
        let url = packageRoot.appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private func referencedKeys() throws -> Set<String> {
        let sources = packageRoot.appendingPathComponent("Sources")
        let pattern = "pluginLocalization\\.string\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*\\)"
        let regex = try NSRegularExpression(pattern: pattern)
        var keys: Set<String> = []
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text) else { return }
                let key = String(text[r])
                if key.contains("\\(") { return }   // 动态插值，跳过
                keys.insert(key)
            }
        }
        return keys
    }

    private func translation(_ strings: [String: Any], _ key: String, _ locale: String) -> String? {
        guard let entry = strings[key] as? [String: Any],
              let locs = entry["localizations"] as? [String: Any],
              let unit = locs[locale] as? [String: Any],
              let su = unit["stringUnit"] as? [String: Any],
              su["state"] as? String == "translated",
              let value = su["value"] as? String, !value.isEmpty else { return nil }
        return value
    }

    @Test func sourceLanguageIsEnglish() throws {
        let url = packageRoot.appendingPathComponent("Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        let strings = try #require(root["strings"] as? [String: Any])
        #expect(!strings.isEmpty)
    }

    @Test func everyReferencedKeyIsFullyTranslated() throws {
        let strings = try catalogStrings()
        let keys = try referencedKeys()
        #expect(keys.count > 400)   //  sanity：扫描确实命中大量调用点
        var missing: [String] = []
        var incomplete: [String] = []
        for key in keys.sorted() {
            guard strings[key] != nil else { missing.append(key); continue }
            for locale in Self.locales where translation(strings, key, locale) == nil {
                incomplete.append("\(key) [\(locale)]")
            }
        }
        #expect(missing.isEmpty, "referenced keys missing from catalog: \(missing)")
        #expect(incomplete.isEmpty, "referenced keys not fully translated: \(incomplete)")
    }

    @Test func p64AuditFixesAreLocalized() throws {
        let strings = try catalogStrings()
        let expected: [String: String] = [
            "Connection Name": "连接名称",
            "Views": "视图",
            "Materialized Views": "物化视图",
            "Triggers": "触发器",
            "Procedures": "存储过程",
            "Functions": "函数",
            "structure changes": "项结构变更",
            "Refresh to load metadata for this object.": "刷新以加载此对象的元数据。",
            "Connect from the sidebar.": "从侧边栏连接。",
            "Click Reload to refresh the table list.": "点击「重新加载」刷新表列表。",
            "All recorded queries will be removed. This cannot be undone.": "所有已记录的查询将被移除。此操作无法撤销。",
            "Clear all query history?": "清除所有查询历史？",
            "Delete this connection?": "删除此连接？",
            "No tables": "无表",
        ]
        for (key, hans) in expected {
            #expect(translation(strings, key, "zh-Hans") == hans, "zh-Hans mismatch for \(key)")
            #expect(translation(strings, key, "en") == key, "en source mismatch for \(key)")
            for locale in Self.locales {
                #expect(translation(strings, key, locale) != nil, "\(key) missing \(locale)")
            }
        }
    }
}