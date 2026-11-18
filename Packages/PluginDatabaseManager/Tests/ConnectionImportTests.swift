import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-8 连接导入：三客户端格式解析的离线单测（合成夹具）+ 真实 TablePlus 文件门控核验。
// 安全：密码/SSH 秘密不随导入搬运；夹具均为合成值，不含真实凭据。

private func plistData(_ object: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

private func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

@Suite(.serialized)
struct ConnectionImportTests {
    // MARK: - TablePlus

    @Test func tablePlusParsesNetworkConnections() throws {
        let entries: [[String: Any]] = [
            [
                "ConnectionName": "Prod PG", "Driver": "PostgreSQL",
                "DatabaseHost": "db.example.com", "DatabasePort": "5433",
                "DatabaseName": "app", "DatabaseUser": "alice",
                "Enviroment": "production", "statusColor": "#DAEBC2",
                "StartupCommands": "SET search_path TO app",
            ],
            [
                "ConnectionName": "Local MySQL", "Driver": "MySQL",
                "DatabaseHost": "127.0.0.1", "DatabasePort": "3307",
                "DatabaseName": "shop", "DatabaseUser": "root",
            ],
        ]
        let configs = try ConnectionImporter.parse(plistData(entries), source: .tablePlus)
        #expect(configs.count == 2)
        // 按名称排序：Local MySQL 在前。
        let mysql = try #require(configs.first { $0.name == "Local MySQL" })
        #expect(mysql.type == .mysql)
        #expect(mysql.host == "127.0.0.1")
        #expect(mysql.port == 3307)
        #expect(mysql.database == "shop")
        #expect(mysql.username == "root")
        #expect(mysql.password == nil)
        let pg = try #require(configs.first { $0.name == "Prod PG" })
        #expect(pg.type == .postgresql)
        #expect(pg.port == 5433)
        #expect(pg.group == "production")
        #expect(pg.connectionColor == .green)
        #expect(pg.startupSQL == "SET search_path TO app")
    }

    @Test func tablePlusSQLiteUsesDatabasePath() throws {
        let entries: [[String: Any]] = [
            ["ConnectionName": "Lite", "Driver": "SQLite", "DatabasePath": "/data/app.sqlite"],
        ]
        let configs = try ConnectionImporter.parse(plistData(entries), source: .tablePlus)
        let config = try #require(configs.first)
        #expect(config.type == .sqlite)
        #expect(config.database == "/data/app.sqlite")
        #expect(config.host == nil)
    }

    @Test func tablePlusFallsBackToDatabaseTypeField() throws {
        let entries: [[String: Any]] = [
            ["ConnectionName": "R", "DatabaseType": "Redis", "DatabaseHost": "cache", "DatabaseName": "2"],
        ]
        let configs = try ConnectionImporter.parse(plistData(entries), source: .tablePlus)
        let config = try #require(configs.first)
        #expect(config.type == .redis)
        #expect(config.port == 6379)
        #expect(config.database == "2")
    }

    @Test func tablePlusSkipsUnknownDriverAndMissingHost() throws {
        let entries: [[String: Any]] = [
            ["ConnectionName": "Unknown", "Driver": "Oracle", "DatabaseHost": "h"],
            ["ConnectionName": "NoHost", "Driver": "MySQL"],
            ["ConnectionName": "", "Driver": "MySQL", "DatabaseHost": "h"],
            ["ConnectionName": "OK", "Driver": "MariaDB", "DatabaseHost": "h", "DatabaseName": "d"],
        ]
        let configs = try ConnectionImporter.parse(plistData(entries), source: .tablePlus)
        #expect(configs.count == 1)
        #expect(configs.first?.name == "OK")
        #expect(configs.first?.type == .mysql)
    }

    @Test func tablePlusDefaultPortWhenMissingOrInvalid() throws {
        let entries: [[String: Any]] = [
            ["ConnectionName": "A", "Driver": "MySQL", "DatabaseHost": "h", "DatabaseName": "d"],
            ["ConnectionName": "B", "Driver": "PostgreSQL", "DatabaseHost": "h", "DatabasePort": "abc", "DatabaseName": "d"],
        ]
        let configs = try ConnectionImporter.parse(plistData(entries), source: .tablePlus)
        #expect(configs.first { $0.name == "A" }?.port == 3306)
        #expect(configs.first { $0.name == "B" }?.port == 5432)
    }

    @Test func tablePlusUnsupportedFormatThrows() {
        #expect(throws: ConnectionImportError.unsupportedFormat) {
            try ConnectionImporter.parse(Data("not a plist".utf8), source: .tablePlus)
        }
        // 合法 plist 但顶层不是数组。
        #expect(throws: ConnectionImportError.unsupportedFormat) {
            try ConnectionImporter.parse(plistData(["key": "value"]), source: .tablePlus)
        }
    }

    // MARK: - Sequel Ace

    @Test func sequelAceParsesFavorites() throws {
        let plist: [String: Any] = [
            "Favorites Root": [
                "children": [
                    ["name": "Shop", "host": "mysql.example.com", "port": 3306, "database": "shop", "user": "bob", "type": "mysql"],
                    ["name": "Folder Only"],
                ],
            ],
        ]
        let configs = try ConnectionImporter.parse(plistData(plist), source: .sequelAce)
        #expect(configs.count == 1)
        let config = try #require(configs.first)
        #expect(config.name == "Shop")
        #expect(config.type == .mysql)
        #expect(config.host == "mysql.example.com")
        #expect(config.port == 3306)
        #expect(config.database == "shop")
        #expect(config.username == "bob")
    }

    @Test func sequelAceImportsPlaintextPasswordAndStringPort() throws {
        let plist: [String: Any] = [
            "Favorites Root": [
                "children": [
                    ["name": "Legacy", "host": "h", "port": "3307", "database": "d", "user": "u", "password": "synthetic-secret"],
                ],
            ],
        ]
        let config = try #require(ConnectionImporter.parse(plistData(plist), source: .sequelAce).first)
        #expect(config.port == 3307)
        #expect(config.password == "synthetic-secret")
    }

    @Test func sequelAceUnsupportedFormatThrows() {
        #expect(throws: ConnectionImportError.unsupportedFormat) {
            try ConnectionImporter.parse(plistData(["no": "root"]), source: .sequelAce)
        }
    }

    @Test func sequelAceParsesCapitalChildrenKey() throws {
        let plist: [String: Any] = [
            "Favorites Root": [
                "IsExpanded": true,
                "Name": "Favorites",
                "Children": [
                    ["name": "Cloud", "host": "127.0.0.1", "port": "", "database": "", "sshHost": "203.0.113.7"],
                ],
            ],
        ]
        let config = try #require(ConnectionImporter.parse(plistData(plist), source: .sequelAce).first)
        #expect(config.name == "Cloud")
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 3306)
        #expect(config.database == "")
    }

    @Test func sequelAceRecursesIntoNestedFolders() throws {
        let plist: [String: Any] = [
            "Favorites Root": [
                "Children": [
                    [
                        "Name": "Production", "IsExpanded": true,
                        "Children": [
                            ["name": "Nested A", "host": "a.example.com", "port": 3306],
                            [
                                "Name": "Sub Folder",
                                "children": [
                                    ["name": "Nested B", "host": "b.example.com", "port": "3307"],
                                ],
                            ],
                        ],
                    ],
                    ["name": "Top Level", "host": "c.example.com"],
                    ["Name": "Empty Folder", "Children": [[String: Any]]()],
                ],
            ],
        ]
        let configs = try ConnectionImporter.parse(plistData(plist), source: .sequelAce)
        #expect(configs.map(\.name) == ["Nested A", "Nested B", "Top Level"])
        #expect(configs.map(\.port) == [3306, 3307, 3306])
    }

    // MARK: - DBeaver

    @Test func dbeaverParsesConnections() throws {
        let json: [String: Any] = [
            "connections": [
                "postgres-jdbc-1": [
                    "provider": "postgresql", "driver": "postgres-jdbc", "name": "Analytics",
                    "configuration": ["host": "pg.example.com", "port": "5432", "database": "analytics", "user": "carol", "password": "encrypted-blob"],
                ],
                "mysql8-2": [
                    "provider": "mysql", "driver": "mysql8", "name": "Shop",
                    "configuration": ["host": "127.0.0.1", "port": "3306", "database": "shop", "user": "root"],
                ],
            ],
        ]
        let configs = try ConnectionImporter.parse(jsonData(json), source: .dbeaver)
        #expect(configs.count == 2)
        let pg = try #require(configs.first { $0.name == "Analytics" })
        #expect(pg.type == .postgresql)
        #expect(pg.host == "pg.example.com")
        #expect(pg.database == "analytics")
        #expect(pg.username == "carol")
        // 加密密码不导入。
        #expect(pg.password == nil)
        #expect(configs.first { $0.name == "Shop" }?.type == .mysql)
    }

    @Test func dbeaverSQLiteFromDatabaseOrJDBCURL() throws {
        let json: [String: Any] = [
            "connections": [
                "sqlite-1": ["provider": "sqlite", "name": "Direct", "configuration": ["database": "/data/direct.sqlite"]],
                "sqlite-2": ["provider": "sqlite", "name": "URL", "configuration": ["url": "jdbc:sqlite:/data/url.sqlite"]],
            ],
        ]
        let configs = try ConnectionImporter.parse(jsonData(json), source: .dbeaver)
        #expect(configs.first { $0.name == "Direct" }?.database == "/data/direct.sqlite")
        #expect(configs.first { $0.name == "URL" }?.database == "/data/url.sqlite")
    }

    @Test func dbeaverSkipsUnsupportedProviderAndMissingHost() throws {
        let json: [String: Any] = [
            "connections": [
                "x": ["provider": "oracle", "name": "X", "configuration": ["host": "h"]],
                "y": ["provider": "mysql", "name": "Y", "configuration": ["database": "d"]],
            ],
        ]
        let configs = try ConnectionImporter.parse(jsonData(json), source: .dbeaver)
        #expect(configs.isEmpty)
    }

    @Test func dbeaverUnsupportedFormatThrows() {
        #expect(throws: ConnectionImportError.unsupportedFormat) {
            try ConnectionImporter.parse(Data("{}".utf8), source: .dbeaver)
        }
        #expect(throws: ConnectionImportError.unsupportedFormat) {
            try ConnectionImporter.parse(Data("not json".utf8), source: .dbeaver)
        }
    }

    // MARK: - 颜色映射与排序

    @Test func colorFromHexMapsByHue() {
        #expect(ConnectionImporter.color(fromHex: "#000000") == .none)
        #expect(ConnectionImporter.color(fromHex: "#F8F8F8") == .none)
        #expect(ConnectionImporter.color(fromHex: "#F8F7BD") == .orange)
        #expect(ConnectionImporter.color(fromHex: "#DAEBC2") == .green)
        #expect(ConnectionImporter.color(fromHex: "#FFD7D4") == .red)
        #expect(ConnectionImporter.color(fromHex: "#3B82F6") == .blue)
        #expect(ConnectionImporter.color(fromHex: "#22D3EE") == .cyan)
        #expect(ConnectionImporter.color(fromHex: "#A855F7") == .purple)
        #expect(ConnectionImporter.color(fromHex: "garbage") == .none)
        #expect(ConnectionImporter.color(fromHex: "#FFF") == .none)
    }

    @Test func resultsAreSortedByName() throws {
        let entries: [[String: Any]] = [
            ["ConnectionName": "Zebra", "Driver": "MySQL", "DatabaseHost": "h", "DatabaseName": "d"],
            ["ConnectionName": "apple", "Driver": "MySQL", "DatabaseHost": "h", "DatabaseName": "d"],
            ["ConnectionName": "Mango", "Driver": "MySQL", "DatabaseHost": "h", "DatabaseName": "d"],
        ]
        let configs = try ConnectionImporter.parse(plistData(entries), source: .tablePlus)
        #expect(configs.map(\.name) == ["apple", "Mango", "Zebra"])
    }

    @Test func importFromMissingFileThrowsUnreadable() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/Connections.plist")
        #expect(throws: ConnectionImportError.fileUnreadable) {
            try ConnectionImporter.importConnections(from: url, source: .tablePlus)
        }
    }

    @Test func everySourceParsesEmptyContainerToEmptyList() throws {
        #expect(try ConnectionImporter.parse(plistData([[String: Any]]()), source: .tablePlus).isEmpty)
        #expect(try ConnectionImporter.parse(plistData(["Favorites Root": ["children": [[String: Any]]()]]), source: .sequelAce).isEmpty)
        #expect(try ConnectionImporter.parse(jsonData(["connections": [String: Any]()]), source: .dbeaver).isEmpty)
    }

    // MARK: - 默认配置文件候选路径

    @Test func sequelAceCandidatesIncludeSandboxContainers() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let paths = ConnectionImporter.candidateURLs(for: .sequelAce, home: home).map(\.path)
        #expect(paths == [
            "/Users/tester/Library/Application Support/Sequel Ace/Data/Favorites.plist",
            "/Users/tester/Library/Application Support/Sequel Pro/Data/Favorites.plist",
            "/Users/tester/Library/Containers/com.sequel-ace.sequel-ace/Data/Library/Application Support/Sequel Ace/Data/Favorites.plist",
            "/Users/tester/Library/Containers/com.sequelpro.SequelPro/Data/Library/Application Support/Sequel Pro/Data/Favorites.plist",
        ])
    }

    @Test func candidateURLsAreAnchoredToHome() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        for source in ConnectionImportSource.allCases {
            let candidates = ConnectionImporter.candidateURLs(for: source, home: home)
            #expect(!candidates.isEmpty)
            for url in candidates {
                #expect(url.path.hasPrefix(home.path))
            }
        }
    }
}

// 真实 TablePlus 配置文件核验（本机已安装 TablePlus 时经 env 指定路径启用）。
// 不提交任何本机路径：路径由 LODE_TEST_TABLEPLUS_PLIST 注入。
@Suite(.serialized)
struct ConnectionImportRealFileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LODE_TEST_TABLEPLUS_PLIST"] != nil))
    func realTablePlusFileParses() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LODE_TEST_TABLEPLUS_PLIST"])
        let url = URL(fileURLWithPath: path)
        let configs = try ConnectionImporter.importConnections(from: url, source: .tablePlus)
        #expect(!configs.isEmpty)
        for config in configs {
            #expect(!config.name.isEmpty)
            #expect(DatabaseType.allCases.contains(config.type))
            // 密码绝不从 plist 搬运。
            #expect(config.password == nil)
            if config.type == .sqlite {
                #expect(!config.database.isEmpty)
            } else {
                #expect(config.host?.isEmpty == false)
            }
        }
    }
}

// 批量入库的去重逻辑（同名+同引擎+同主机+同库视为重复，含批次内重复）。
@MainActor
@Suite(.serialized)
struct ConnectionImportViewModelTests {
    @Test func importAddsAndDeduplicates() {
        let vm = DatabaseViewModel(loadSavedConfigs: false)
        let base = vm.configs.count
        let a = DatabaseConfig(name: "Imp A", type: .mysql, host: "h", port: 3306, database: "d", username: "u")
        let b = DatabaseConfig(name: "Imp B", type: .postgresql, host: "h2", port: 5432, database: "d2", username: "u")
        // 批次内 a 重复一次，应只新增 2 条。
        #expect(vm.importConfigs([a, b, a]) == 2)
        #expect(vm.configs.count == base + 2)
        // 再次导入相同连接全部命中去重。
        #expect(vm.importConfigs([a, b]) == 0)
        #expect(vm.configs.count == base + 2)
    }

    @Test func importDifferentHostIsNotDuplicate() {
        let vm = DatabaseViewModel(loadSavedConfigs: false)
        let base = vm.configs.count
        let a = DatabaseConfig(name: "Same", type: .mysql, host: "h1", port: 3306, database: "d", username: "u")
        let b = DatabaseConfig(name: "Same", type: .mysql, host: "h2", port: 3306, database: "d", username: "u")
        #expect(vm.importConfigs([a, b]) == 2)
        #expect(vm.configs.count == base + 2)
    }

    @Test func importEmptyReturnsZero() {
        let vm = DatabaseViewModel(loadSavedConfigs: false)
        #expect(vm.importConfigs([]) == 0)
    }
}