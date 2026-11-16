import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-6 百万行性能验收（env 门控 LODE_TEST_PERF=1，避免拖慢常规套件）：
// 真实 SQLite 百万行表，对比深翻页 OFFSET 与 keyset 的耗时与正确性，
// 并验证 VM 打开百万行表 + keyset 首页 + 近似/精确计数路径可用。
// 运行：LODE_TEST_PERF=1 swift test --filter MillionRowPerformanceTests

private func perfEnabled() -> Bool {
    ProcessInfo.processInfo.environment["LODE_TEST_PERF"] == "1"
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct MillionRowPerformanceTests {
    private func makeSUT() async -> (DatabaseViewModel, DatabaseManagerCore) {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        let viewModel = DatabaseViewModel(loadSavedConfigs: false, manager: manager)
        return (viewModel, manager)
    }

    @Test(.enabled(if: perfEnabled()))
    func millionRowKeysetDeepPaging() async throws {
        let (vm, _) = await makeSUT()
        let path = NSTemporaryDirectory() + "lode-perf-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = DatabaseConfig(name: "perf", type: .sqlite, database: path)
        await vm.connect(config: config)
        #expect(vm.isConnected)
        let other = try SQLiteConnection(path: path)
        defer { Task { await other.close() } }

        _ = try await other.execute("CREATE TABLE perf_million (id INTEGER PRIMARY KEY, name TEXT)", params: nil)
        // 递归 CTE 一次性生成百万行。
        _ = try await other.execute(
            """
            INSERT INTO perf_million (id, name)
            WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 1000000)
            SELECT x, 'name-' || x FROM seq
            """, params: nil)
        let total = try await other.query("SELECT COUNT(*) FROM perf_million", params: nil)
        #expect(total.rows.first?.first == .integer(1_000_000))

        // 深翻页对比：OFFSET 999900 vs keyset id > 999900。
        let offsetStart = Date()
        let offsetResult = try await other.query("SELECT id FROM perf_million ORDER BY id LIMIT 100 OFFSET 999900", params: nil)
        let offsetElapsed = Date().timeIntervalSince(offsetStart)

        let keysetStart = Date()
        let keysetResult = try await other.query("SELECT id FROM perf_million WHERE id > 999900 ORDER BY id LIMIT 100", params: nil)
        let keysetElapsed = Date().timeIntervalSince(keysetStart)

        let expected = Array(999_901...1_000_000)
        #expect(offsetResult.rows.compactMap { $0.first } == expected.map { DatabaseValue.integer($0) })
        #expect(keysetResult.rows.compactMap { $0.first } == expected.map { DatabaseValue.integer($0) })
        // keyset 深翻页应在合理时间内完成（不随页深线性劣化）。
        #expect(keysetElapsed < 2.0)
        print("[perf] million-row deep page OFFSET=\(offsetElapsed)s keyset=\(keysetElapsed)s")

        // VM 路径：打开百万行表 + 主键排序 + keyset 首页。
        await vm.openObject(DatabaseObject(kind: .table, name: "perf_million"))
        await vm.toggleSort(column: "id")
        await vm.setPageSize(100)
        await vm.setUseKeysetPagination(true)
        #expect(vm.keysetAvailable == true)
        #expect(vm.queryResult?.rows.count == 100)
        #expect(vm.queryText.contains("OFFSET") == false)
        await vm.nextPage()
        #expect(vm.queryResult?.rows.first?.first == .integer(101))
        // 精确计数可达百万。
        await vm.refreshExactRowCount()
        #expect(vm.tableRowCount == 1_000_000)
        #expect(vm.tableRowCountIsApproximate == false)
    }
}