import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 能力声明一致性守卫：声明必须与实现同步。
/// 未实现的特性（SSH 隧道、密码来源、Redis TLS）一律 false；
/// 对应功能落地时更新本快照并在同一提交翻 true。
struct DatabaseCapabilitiesTests {
    @Test("SSH 尚未实现：所有引擎声明 false", arguments: DatabaseType.allCases)
    func sshNotImplemented(type: DatabaseType) {
        #expect(type.capabilities.supportsSSH == false)
    }

    @Test("密码来源尚未实现：所有引擎声明 false", arguments: DatabaseType.allCases)
    func passwordSourcesNotImplemented(type: DatabaseType) {
        #expect(type.capabilities.supportsPasswordSources == false)
    }

    @Test("Redis 尚无 TLS：supportsSSL 为 false")
    func redisNoTLS() {
        #expect(DatabaseType.redis.capabilities.supportsSSL == false)
    }

    @Test("SQLite 本地文件：无 SSL/多库/schema")
    func sqliteLocalFile() {
        let caps = DatabaseType.sqlite.capabilities
        #expect(caps.supportsSSL == false)
        #expect(caps.supportsMultipleDatabases == false)
        #expect(caps.supportsSchemas == false)
    }

    @Test("已实现能力保持 true（防误删）")
    func implementedCapabilitiesStay() {
        #expect(DatabaseType.sqlite.capabilities.supportsTransactions)
        #expect(DatabaseType.mysql.capabilities.supportsSSL)
        #expect(DatabaseType.postgresql.capabilities.supportsSSL)
        #expect(DatabaseType.postgresql.capabilities.supportsSchemas)
        #expect(DatabaseType.mysql.capabilities.supportsMultipleDatabases)
        for type in DatabaseType.allCases {
            // P1-2 起 defaultQueryLimit 驱动编辑器行数上限，声明必须与默认值一致。
            #expect(type.capabilities.defaultQueryLimit == 1000)
        }
    }
}