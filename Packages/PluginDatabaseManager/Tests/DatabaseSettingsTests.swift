import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P6-3a 离线单测：设置模型 Codable 往返/默认/向后兼容/映射 + 存储往返；
// VM 设置→行为联动（格式化关键字大小写、连接行数上限、跨重开持久）。

@Suite(.serialized)
struct DatabaseSettingsModelTests {
    private func makeSuite() -> String { "lode-settings-\(UUID().uuidString)" }

    private func cleanup(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func defaultsAreSane() {
        let s = DatabaseSettings()
        #expect(s.defaultQueryRowLimit == 0)
        #expect(s.defaultSafeMode == "off")
        #expect(s.editorFontSize == 0)
        #expect(s.keywordCase == "upper")
        #expect(s.indentWidth == 2)
        #expect(s.useTabs == false)
        #expect(s.clausePerLine == true)
        #expect(s.commaNewlineInList == true)
        #expect(s.debugLoggingEnabled == false)
    }

    @Test func codableRoundTrip() throws {
        let s = DatabaseSettings(
            defaultQueryRowLimit: 250,
            defaultSafeMode: "readOnly",
            editorFontSize: 15,
            keywordCase: "lower",
            indentWidth: 4,
            useTabs: true,
            clausePerLine: false,
            commaNewlineInList: false,
            debugLoggingEnabled: true
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(DatabaseSettings.self, from: data)
        #expect(decoded == s)
    }

    @Test func decoderFillsMissingKeysWithDefaults() throws {
        let data = Data("{\"keywordCase\":\"lower\"}".utf8)
        let decoded = try JSONDecoder().decode(DatabaseSettings.self, from: data)
        #expect(decoded.keywordCase == "lower")
        #expect(decoded.defaultQueryRowLimit == 0)
        #expect(decoded.indentWidth == 2)
        #expect(decoded.commaNewlineInList == true)
        #expect(decoded.debugLoggingEnabled == false)
    }

    @Test func formatterOptionsMapsKeywordCase() {
        #expect(DatabaseSettings(keywordCase: "upper").formatterOptions.keywordCase == .upper)
        #expect(DatabaseSettings(keywordCase: "lower").formatterOptions.keywordCase == .lower)
        #expect(DatabaseSettings(keywordCase: "preserve").formatterOptions.keywordCase == .preserve)
        #expect(DatabaseSettings(keywordCase: "bogus").formatterOptions.keywordCase == .upper)
    }

    @Test func formatterOptionsClampsIndentWidth() {
        #expect(DatabaseSettings(indentWidth: 0).formatterOptions.indentWidth == 1)
        #expect(DatabaseSettings(indentWidth: -3).formatterOptions.indentWidth == 1)
        #expect(DatabaseSettings(indentWidth: 4).formatterOptions.indentWidth == 4)
    }

    @Test func formatterOptionsCarriesLayoutFlags() {
        let options = DatabaseSettings(useTabs: true, clausePerLine: false, commaNewlineInList: false).formatterOptions
        #expect(options.useTabs == true)
        #expect(options.clausePerLine == false)
        #expect(options.commaNewlineInList == false)
    }

    @Test func safeModeMapsRawValueWithFallback() {
        #expect(DatabaseSettings(defaultSafeMode: "off").safeMode == .off)
        #expect(DatabaseSettings(defaultSafeMode: "confirm").safeMode == .confirmWrites)
        #expect(DatabaseSettings(defaultSafeMode: "readOnly").safeMode == .readOnly)
        #expect(DatabaseSettings(defaultSafeMode: "nonsense").safeMode == .off)
    }

    @Test func storeRoundTripAndPersistAcrossReopen() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let store = DatabaseSettingsStore(defaults: defaults)
        let s = DatabaseSettings(defaultQueryRowLimit: 80, editorFontSize: 13, keywordCase: "preserve")
        store.save(s)
        #expect(DatabaseSettingsStore(defaults: defaults).load() == s)
    }

    @Test func storeReturnsDefaultsWhenEmpty() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let store = DatabaseSettingsStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(store.load() == DatabaseSettings())
    }

    @Test func storeReturnsDefaultsOnCorruptData() {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("not json".utf8), forKey: "DatabaseManager.settings")
        #expect(DatabaseSettingsStore(defaults: defaults).load() == DatabaseSettings())
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DatabaseSettingsViewModelTests {
    private func makeSuite() -> String { "lode-settingsvm-\(UUID().uuidString)" }

    private func cleanup(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func makeSUT(_ suite: String) async -> DatabaseViewModel {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        return DatabaseViewModel(loadSavedConfigs: false, manager: manager, workspaceDefaults: UserDefaults(suiteName: suite)!)
    }

    @Test func formatRespectsKeywordCaseSetting() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.queryText = "select * from t"
        vm.settings.keywordCase = "upper"
        vm.formatDocumentOrSelection()
        #expect(vm.queryText.contains("SELECT"))
        #expect(vm.queryText.contains("FROM"))

        vm.queryText = "select * from t"
        vm.settings.keywordCase = "lower"
        vm.formatDocumentOrSelection()
        #expect(vm.queryText.contains("select"))
        #expect(!vm.queryText.contains("SELECT"))
    }

    @Test func settingsPersistAcrossReopen() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        vm.settings.defaultQueryRowLimit = 123
        vm.settings.editorFontSize = 16
        vm.settings.keywordCase = "lower"
        vm.settings.debugLoggingEnabled = true
        let reopened = await makeSUT(suite)
        #expect(reopened.settings.defaultQueryRowLimit == 123)
        #expect(reopened.settings.editorFontSize == 16)
        #expect(reopened.settings.keywordCase == "lower")
        #expect(reopened.settings.debugLoggingEnabled == true)
    }

    @Test func debugLoggingSettingDrivesSharedLogGate() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        // 设置与断言之间无挂起点，MainActor 上同步执行，避免跨套件并行翻转全局开关。
        vm.settings.debugLoggingEnabled = true
        #expect(DatabaseManagerPluginSupport.debugLog.debugEnabled)
        vm.settings.debugLoggingEnabled = false
        #expect(!DatabaseManagerPluginSupport.debugLog.debugEnabled)
    }

    @Test func defaultSafeModeReflectsSetting() async {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let vm = await makeSUT(suite)
        #expect(vm.defaultSafeMode == .off)
        vm.settings.defaultSafeMode = "readOnly"
        #expect(vm.defaultSafeMode == .readOnly)
    }

    @Test func connectAppliesDefaultQueryRowLimit() async throws {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let vm = DatabaseViewModel(loadSavedConfigs: false, manager: manager, workspaceDefaults: UserDefaults(suiteName: suite)!)
        let config = DatabaseConfig(name: "mem", type: .sqlite, database: ":memory:")
        vm.settings.defaultQueryRowLimit = 50
        await vm.connect(config: config)
        #expect(vm.queryRowLimit == 50)
        await manager.disconnect(configId: config.id)
    }

    @Test func connectFallsBackToEngineDefaultWhenLimitZero() async throws {
        let suite = makeSuite()
        defer { cleanup(suite) }
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let vm = DatabaseViewModel(loadSavedConfigs: false, manager: manager, workspaceDefaults: UserDefaults(suiteName: suite)!)
        let config = DatabaseConfig(name: "mem", type: .sqlite, database: ":memory:")
        vm.settings.defaultQueryRowLimit = 0
        await vm.connect(config: config)
        #expect(vm.queryRowLimit == config.type.capabilities.defaultQueryLimit)
        await manager.disconnect(configId: config.id)
    }
}