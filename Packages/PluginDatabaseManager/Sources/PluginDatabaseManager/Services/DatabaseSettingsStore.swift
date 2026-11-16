import Foundation

/// ``DatabaseSettings`` 的 JSON 持久化存储（注入 UserDefaults，便于测试隔离）。
public struct DatabaseSettingsStore {
    static let settingsKey = "DatabaseManager.settings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取设置；缺失或损坏时回退默认值。
    public func load() -> DatabaseSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(DatabaseSettings.self, from: data) else {
            return DatabaseSettings()
        }
        return settings
    }

    /// 写入设置。
    public func save(_ settings: DatabaseSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }
}