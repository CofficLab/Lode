import Foundation

/// 收藏查询与代码片段的持久化存储（JSON 数组存入 UserDefaults，与导出预设/连接配置同策略）。
///
/// 注入 `UserDefaults` 以便测试隔离；生产用 `.standard`。收藏查询按连接名组织，片段全局共享。
public struct SavedQueryStore {
    public static let queriesKey = "DatabaseManager.savedQueries"
    public static let snippetsKey = "DatabaseManager.snippets"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadQueries() -> [SavedQuery] {
        guard let data = defaults.data(forKey: Self.queriesKey),
              let decoded = try? JSONDecoder().decode([SavedQuery].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveQueries(_ queries: [SavedQuery]) {
        if let data = try? JSONEncoder().encode(queries) {
            defaults.set(data, forKey: Self.queriesKey)
        }
    }

    public func loadSnippets() -> [Snippet] {
        guard let data = defaults.data(forKey: Self.snippetsKey),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveSnippets(_ snippets: [Snippet]) {
        if let data = try? JSONEncoder().encode(snippets) {
            defaults.set(data, forKey: Self.snippetsKey)
        }
    }
}