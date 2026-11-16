import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 连接组织模型：分组名、颜色标签、startup SQL 的 options 往返、归一化与共存。
struct ConnectionOrganizationTests {
    private func baseConfig() -> DatabaseConfig {
        DatabaseConfig(name: "db", type: .postgresql, host: "db.internal", port: 5432, database: "testdb", username: "u")
    }

    @Test("分组名往返保持一致")
    func groupRoundTrip() {
        let config = baseConfig().withGroup("Production")
        #expect(config.group == "Production")
    }

    @Test("未设置时 group 为 nil")
    func groupAbsentIsNil() {
        #expect(baseConfig().group == nil)
    }

    @Test("分组名 trim 外层空白；全空白/nil 移除键并归 nil options")
    func groupTrimsAndEmptyClears() {
        let config = baseConfig().withGroup("  Production  ")
        #expect(config.group == "Production")
        let blank = baseConfig().withGroup("   ")
        #expect(blank.group == nil)
        #expect(blank.options == nil)
        let removed = config.withGroup(nil)
        #expect(removed.group == nil)
        #expect(removed.options == nil)
    }

    @Test("颜色标签往返；默认 none；none 移除键")
    func colorRoundTrip() {
        #expect(baseConfig().connectionColor == .none)
        let config = baseConfig().withConnectionColor(.red)
        #expect(config.connectionColor == .red)
        let removed = config.withConnectionColor(.none)
        #expect(removed.connectionColor == .none)
        #expect(removed.options == nil)
    }

    @Test("无法识别的颜色 rawValue 回退 none")
    func unknownColorFallsBack() {
        var config = baseConfig()
        config.options = ["color": "magenta"]
        #expect(config.connectionColor == .none)
    }

    @Test("startup SQL 往返；trim 外层空白但保留内部换行/分号")
    func startupSQLRoundTrip() {
        let sql = "SET statement_timeout = 5000;\nSET search_path TO app;"
        let config = baseConfig().withStartupSQL("  \(sql)  ")
        #expect(config.startupSQL == sql)
    }

    @Test("未设置/全空白 startup SQL 为 nil 并移除键")
    func startupSQLEmptyClears() {
        #expect(baseConfig().startupSQL == nil)
        let config = baseConfig().withStartupSQL("SELECT 1;")
        #expect(config.startupSQL != nil)
        let blank = config.withStartupSQL("   ")
        #expect(blank.startupSQL == nil)
        #expect(blank.options == nil)
        let removed = config.withStartupSQL(nil)
        #expect(removed.startupSQL == nil)
    }

    @Test("分组/颜色/startup 与安全模式、SSL、SSH 共存")
    func coexistsWithOtherOptions() {
        let config = baseConfig()
            .withGroup("Production")
            .withConnectionColor(.red)
            .withStartupSQL("SET statement_timeout = 5000;")
            .withSafeMode(.readOnly)
            .withSSLOption(.verifyFull)
            .withSSHConfig(ConnectionSSHConfig(host: "jump", username: "u", password: "p"))
        #expect(config.group == "Production")
        #expect(config.connectionColor == .red)
        #expect(config.startupSQL == "SET statement_timeout = 5000;")
        #expect(config.safeMode == .readOnly)
        #expect(config.sslOption == .verifyFull)
        #expect(config.sshConfig?.host == "jump")
    }

    @Test("逐一移除全部组织选项后 options 归 nil")
    func removingAllClearsOptions() {
        let config = baseConfig()
            .withGroup("Prod")
            .withConnectionColor(.blue)
            .withStartupSQL("SELECT 1;")
            .withGroup(nil)
            .withConnectionColor(.none)
            .withStartupSQL(nil)
        #expect(config.options == nil)
    }

    @Test("颜色枚举覆盖全部 case 且 displayTitle 非空")
    func colorCasesHaveTitles() {
        for color in ConnectionColor.allCases {
            #expect(!color.displayTitle.isEmpty)
            #expect(baseConfig().withConnectionColor(color).connectionColor == color)
        }
    }
}