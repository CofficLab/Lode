import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-1 真实引擎验收：从 introspection 外键生成 ER 图。
// - SQLite（本地、隔离临时库，始终运行）：父→子→孙 FK 链，节点/边/键标记精确，
//   布局确定（重载位置不变），Mermaid/SVG 导出含表名，画布尺寸非零；
// - PostgreSQL / MySQL（Docker，按端口环境变量启用）：独立随机 schema/库，
//   经 ViewModel 切换上下文后 loadERDiagram，节点/边正确且可导出。
//
// 全部只读：建表/清理走驱动直连，不经写闸门；图加载不修改数据库。

private func erPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ERDiagramIntegrationTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    private func node(_ diagram: ERDiagram, named name: String) -> ERNode? {
        diagram.nodes.first { $0.name == name }
    }

    private func assertChain(_ diagram: ERDiagram, parent: String, child: String, grandchild: String, childFK: String, grandchildFK: String) throws {
        let parentNode = try #require(node(diagram, named: parent))
        let childNode = try #require(node(diagram, named: child))
        let grandchildNode = try #require(node(diagram, named: grandchild))

        // 子→父、孙→子两条边。
        #expect(diagram.edges.contains { $0.fromNode == childNode.id && $0.toNode == parentNode.id })
        #expect(diagram.edges.contains { $0.fromNode == grandchildNode.id && $0.toNode == childNode.id })

        // 键标记：父 id 为主键；子外键列被标记。
        #expect(parentNode.columns.contains { $0.name == "id" && $0.isPrimaryKey })
        #expect(childNode.columns.contains { $0.name == childFK && $0.isForeignKey })
        #expect(grandchildNode.columns.contains { $0.name == grandchildFK && $0.isForeignKey })

        // 画布与导出。
        #expect(diagram.canvasSize.width > 0)
        #expect(diagram.canvasSize.height > 0)
        let mermaid = diagram.mermaidRepresentation()
        #expect(mermaid.contains("erDiagram"))
        #expect(mermaid.contains(parent))
        #expect(mermaid.contains(child))
        let svg = diagram.svgRepresentation()
        #expect(svg.contains("<svg"))
        #expect(svg.contains(parent))
        #expect(svg.contains(grandchild))
    }

    // MARK: - SQLite（始终运行）

    @Test func sqliteForeignKeyChainBuildsDiagramAndExports() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-er-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "er", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }

        _ = try await other.execute("CREATE TABLE er_parent (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", params: nil)
        _ = try await other.execute(
            "CREATE TABLE er_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES er_parent(id), label TEXT)", params: nil)
        _ = try await other.execute(
            "CREATE TABLE er_grandchild (id INTEGER PRIMARY KEY, child_id INTEGER REFERENCES er_child(id))", params: nil)

        // 表经独立连接在 connect 之后创建，强制刷新绕过连接期缓存的空表列表。
        await vm.loadERDiagram(refresh: true)
        #expect(vm.erDiagramError == nil)
        let diagram = try #require(vm.erDiagram)
        try assertChain(diagram, parent: "er_parent", child: "er_child", grandchild: "er_grandchild", childFK: "parent_id", grandchildFK: "child_id")

        // 布局确定性：强制重载后各节点位置不变。
        let positions = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, $0.position) })
        await vm.loadERDiagram(refresh: true)
        let reloaded = try #require(vm.erDiagram)
        for n in reloaded.nodes {
            #expect(positions[n.id] == n.position)
        }

        _ = try await other.execute("DROP TABLE IF EXISTS er_grandchild", params: nil)
        _ = try await other.execute("DROP TABLE IF EXISTS er_child", params: nil)
        _ = try await other.execute("DROP TABLE IF EXISTS er_parent", params: nil)
        await vm.disconnect()
    }

    // MARK: - PostgreSQL（Docker）

    @Test(.enabled(if: erPort("LODE_TEST_PG_PORT") != nil))
    func pgForeignKeyChainBuildsDiagramInCustomSchema() async throws {
        let port = try #require(erPort("LODE_TEST_PG_PORT"))
        let schema = "er_\(UUID().uuidString.prefix(8).lowercased())"
        let quoted = "\"\(schema)\""
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "er", type: .postgresql, host: "127.0.0.1", port: port, database: "testdb", username: "postgres", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let conn = try #require(await manager.getConnection(for: config.id))
        defer { Task { _ = try? await conn.execute("DROP SCHEMA IF EXISTS \(quoted) CASCADE", params: nil); await vm.disconnect() } }
        _ = try await conn.execute("CREATE SCHEMA \(quoted)", params: nil)
        _ = try await conn.execute("CREATE TABLE \(quoted).er_parent (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", params: nil)
        _ = try await conn.execute(
            "CREATE TABLE \(quoted).er_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES \(quoted).er_parent(id), label TEXT)", params: nil)
        _ = try await conn.execute(
            "CREATE TABLE \(quoted).er_grandchild (id INTEGER PRIMARY KEY, child_id INTEGER REFERENCES \(quoted).er_child(id))", params: nil)

        await vm.switchSchema(schema)
        #expect(vm.activeSchema == schema)
        await vm.loadERDiagram()
        #expect(vm.erDiagramError == nil)
        let diagram = try #require(vm.erDiagram)
        try assertChain(diagram, parent: "er_parent", child: "er_child", grandchild: "er_grandchild", childFK: "parent_id", grandchildFK: "child_id")
    }

    // MARK: - MySQL（Docker）

    @Test(.enabled(if: erPort("LODE_TEST_MYSQL_PORT") != nil))
    func mysqlForeignKeyChainBuildsDiagramInCustomDatabase() async throws {
        let port = try #require(erPort("LODE_TEST_MYSQL_PORT"))
        let database = "er_\(UUID().uuidString.prefix(8).lowercased())"
        let (vm, manager) = await makeSUT()
        let config = DatabaseConfig(name: "er", type: .mysql, host: "127.0.0.1", port: port, database: "testdb", username: "root", password: "test").withSafeMode(.off)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let seed = try #require(await manager.getConnection(for: config.id))
        _ = try await seed.execute("CREATE DATABASE `\(database)`", params: nil)
        _ = try await seed.execute("CREATE TABLE `\(database)`.er_parent (id INT PRIMARY KEY, name VARCHAR(64) NOT NULL) ENGINE=InnoDB", params: nil)
        _ = try await seed.execute(
            "CREATE TABLE `\(database)`.er_child (id INT PRIMARY KEY, parent_id INT, label VARCHAR(64), CONSTRAINT fk_er_child FOREIGN KEY (parent_id) REFERENCES `\(database)`.er_parent(id)) ENGINE=InnoDB", params: nil)
        _ = try await seed.execute(
            "CREATE TABLE `\(database)`.er_grandchild (id INT PRIMARY KEY, child_id INT, CONSTRAINT fk_er_grandchild FOREIGN KEY (child_id) REFERENCES `\(database)`.er_child(id)) ENGINE=InnoDB", params: nil)
        defer { Task {
            if let live = await manager.getConnection(for: config.id) {
                _ = try? await live.execute("DROP DATABASE IF EXISTS `\(database)`", params: nil)
            }
            await vm.disconnect()
        } }

        await vm.switchDatabase(database)
        #expect(vm.activeDatabase == database)
        await vm.loadERDiagram()
        #expect(vm.erDiagramError == nil)
        let diagram = try #require(vm.erDiagram)
        try assertChain(diagram, parent: "er_parent", child: "er_child", grandchild: "er_grandchild", childFK: "parent_id", grandchildFK: "child_id")
    }
}