import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P4-3e 真实 Redis 引擎验收：六类型（string/hash/list/set/zset/stream）浏览 + 编辑往返，
// 以及 TTL 设置/持久化/删除、命名空间键树聚合与 SCAN 分页。
//
// 需本地 Docker：设置 LODE_TEST_REDIS_PORT 后启用（默认 db0，无密码）。
// 每个用例用独立随机前缀建键，结束时经独立第二连接 DEL 清理，互不污染。
// 编辑往返用 safeMode=.off（写直接放行），落库结果由独立连接核验，证明真正写入引擎。

private func rkPort(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

private func rkCell(_ result: QueryResult, _ row: Int, _ col: Int) -> DatabaseValue {
    guard row < result.rows.count, col < result.rows[row].count else { return .null }
    return result.rows[row][col]
}

private func rkText(_ value: DatabaseValue) -> String {
    if case .string(let s) = value { return s }
    return value.description
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct RedisKeyBrowserIntegrationTests {
    private func makeSUT() async -> DatabaseViewModel {
        let manager = DatabaseManagerCore()
        await DatabaseDriverBootstrap.registerBuiltinsIfNeeded(on: manager)
        return DatabaseViewModel(loadSavedConfigs: false, manager: manager)
    }

    private func connect(_ vm: DatabaseViewModel, port: Int, mode: ConnectionSafeMode = .off) async {
        let config = DatabaseConfig(name: "rk", type: .redis, host: "127.0.0.1", port: port, database: "0").withSafeMode(mode)
        await vm.connect(config: config)
    }

    private func cleanup(_ other: RedisConnection, keys: [String]) async {
        guard !keys.isEmpty else { return }
        _ = try? await other.execute("DEL", params: keys.map { .string($0) })
    }

    // MARK: - String

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func stringBrowseEditRoundTrip() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let key = "\(prefix):str"
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: [key]); await other.close() } }
        _ = try await other.execute("SET", params: [.string(key), .string("hello")])
        await connect(vm, port: port)
        #expect(vm.isConnected)
        await vm.loadRedisKeys()
        #expect(vm.redisKeys.contains(key))
        await vm.openRedisKey(key)
        #expect(vm.selectedRedisKey?.type == .string)
        #expect(vm.selectedRedisValue == .string(.string("hello")))
        await vm.applyRedisEdit(.setString(key: key, value: "world"))
        #expect(vm.selectedRedisValue == .string(.string("world")))
        let landed = try await other.query("GET", params: [.string(key)])
        #expect(rkText(rkCell(landed, 0, 1)) == "world")
        await vm.disconnect()
    }

    // MARK: - Hash

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func hashBrowseEditRoundTrip() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let key = "\(prefix):hash"
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: [key]); await other.close() } }
        _ = try await other.execute("HSET", params: [.string(key), .string("f1"), .string("v1"), .string("f2"), .string("v2")])
        await connect(vm, port: port)
        await vm.openRedisKey(key)
        #expect(vm.selectedRedisKey?.type == .hash)
        guard case .hash(let entries) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected hash value"); return
        }
        #expect(entries.contains(RedisHashEntry(field: "f1", value: .string("v1"))))
        #expect(entries.contains(RedisHashEntry(field: "f2", value: .string("v2"))))
        await vm.applyRedisEdit(.hashSet(key: key, field: "f3", value: "v3"))
        guard case .hash(let afterAdd) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected hash value after add"); return
        }
        #expect(afterAdd.contains(RedisHashEntry(field: "f3", value: .string("v3"))))
        await vm.applyRedisEdit(.hashDelete(key: key, field: "f1"))
        guard case .hash(let afterDel) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected hash value after delete"); return
        }
        #expect(!afterDel.contains { $0.field == "f1" })
        #expect(afterDel.count == 2)
        let landed = try await other.query("HGETALL", params: [.string(key)])
        #expect(landed.rows.count == 2)
        await vm.disconnect()
    }

    // MARK: - List

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func listBrowseEditRoundTrip() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let key = "\(prefix):list"
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: [key]); await other.close() } }
        _ = try await other.execute("RPUSH", params: [.string(key), .string("a"), .string("b"), .string("c")])
        await connect(vm, port: port)
        await vm.openRedisKey(key)
        #expect(vm.selectedRedisKey?.type == .list)
        #expect(vm.selectedRedisValue == .list([.string("a"), .string("b"), .string("c")]))
        await vm.applyRedisEdit(.listPush(key: key, value: "d"))
        #expect(vm.selectedRedisValue == .list([.string("a"), .string("b"), .string("c"), .string("d")]))
        await vm.applyRedisEdit(.listSet(key: key, index: 0, value: "A"))
        guard case .list(let afterSet) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected list value after set"); return
        }
        #expect(afterSet.first == .string("A"))
        await vm.applyRedisEdit(.listRemove(key: key, value: "b"))
        guard case .list(let afterRemove) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected list value after remove"); return
        }
        #expect(!afterRemove.contains(.string("b")))
        let landed = try await other.query("LRANGE", params: [.string(key), .string("0"), .string("-1")])
        #expect(landed.rows.map { rkText($0[0]) } == ["A", "c", "d"])
        await vm.disconnect()
    }

    // MARK: - Set

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func setBrowseEditRoundTrip() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let key = "\(prefix):set"
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: [key]); await other.close() } }
        _ = try await other.execute("SADD", params: [.string(key), .string("x"), .string("y"), .string("z")])
        await connect(vm, port: port)
        await vm.openRedisKey(key)
        #expect(vm.selectedRedisKey?.type == .set)
        guard case .set(let members) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected set value"); return
        }
        #expect(Set(members.map(rkText)) == ["x", "y", "z"])
        await vm.applyRedisEdit(.setAdd(key: key, member: "w"))
        guard case .set(let afterAdd) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected set value after add"); return
        }
        #expect(afterAdd.contains(.string("w")))
        await vm.applyRedisEdit(.setRemove(key: key, member: "x"))
        guard case .set(let afterRemove) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected set value after remove"); return
        }
        #expect(!afterRemove.contains(.string("x")))
        let landed = try await other.query("SMEMBERS", params: [.string(key)])
        #expect(Set(landed.rows.map { rkText($0[0]) }) == ["y", "z", "w"])
        await vm.disconnect()
    }

    // MARK: - Sorted Set

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func zsetBrowseEditRoundTrip() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let key = "\(prefix):zset"
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: [key]); await other.close() } }
        _ = try await other.execute("ZADD", params: [.string(key), .string("1"), .string("a"), .string("2"), .string("b")])
        await connect(vm, port: port)
        await vm.openRedisKey(key)
        #expect(vm.selectedRedisKey?.type == .zset)
        guard case .zset(let entries) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected zset value"); return
        }
        #expect(entries.contains(RedisZSetEntry(member: .string("a"), score: 1)))
        #expect(entries.contains(RedisZSetEntry(member: .string("b"), score: 2)))
        await vm.applyRedisEdit(.zsetAdd(key: key, member: "c", score: 3))
        guard case .zset(let afterAdd) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected zset value after add"); return
        }
        #expect(afterAdd.contains(RedisZSetEntry(member: .string("c"), score: 3)))
        await vm.applyRedisEdit(.zsetRemove(key: key, member: "a"))
        guard case .zset(let afterRemove) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected zset value after remove"); return
        }
        #expect(!afterRemove.contains { rkText($0.member) == "a" })
        let landed = try await other.query("ZRANGE", params: [.string(key), .string("0"), .string("-1"), .string("WITHSCORES")])
        #expect(landed.rows.count == 2)
        await vm.disconnect()
    }

    // MARK: - Stream

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func streamBrowseEditRoundTrip() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let key = "\(prefix):stream"
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: [key]); await other.close() } }
        _ = try await other.execute("XADD", params: [.string(key), .string("*"), .string("f1"), .string("v1")])
        await connect(vm, port: port)
        await vm.openRedisKey(key)
        #expect(vm.selectedRedisKey?.type == .stream)
        guard case .stream(let entries) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected stream value"); return
        }
        #expect(entries.count == 1)
        #expect(entries[0].fields.contains(RedisHashEntry(field: "f1", value: .string("v1"))))
        let firstID = entries[0].id
        await vm.applyRedisEdit(.streamAdd(key: key, fields: [RedisHashEntry(field: "f2", value: .string("v2"))]))
        guard case .stream(let afterAdd) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected stream value after add"); return
        }
        #expect(afterAdd.count == 2)
        await vm.applyRedisEdit(.streamDelete(key: key, id: firstID))
        guard case .stream(let afterDelete) = try #require(vm.selectedRedisValue) else {
            Issue.record("expected stream value after delete"); return
        }
        #expect(afterDelete.count == 1)
        #expect(afterDelete[0].id != firstID)
        let landed = try await other.query("XLEN", params: [.string(key)])
        #expect(rkText(rkCell(landed, 0, 0)) == "1")
        await vm.disconnect()
    }

    // MARK: - TTL / Persist / Delete

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func ttlPersistDeleteRoundTrip() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let key = "\(prefix):ttl"
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: [key]); await other.close() } }
        _ = try await other.execute("SET", params: [.string(key), .string("v")])
        await connect(vm, port: port)
        await vm.loadRedisKeys()
        await vm.openRedisKey(key)
        #expect(vm.selectedRedisKey?.ttl == -1)
        await vm.applyRedisEdit(.setTTL(key: key, seconds: 100))
        let ttl = try #require(vm.selectedRedisKey?.ttl)
        #expect(ttl > 0 && ttl <= 100)
        await vm.applyRedisEdit(.persist(key: key))
        #expect(vm.selectedRedisKey?.ttl == -1)
        await vm.applyRedisEdit(.delete(key: key))
        #expect(vm.selectedRedisKey == nil)
        #expect(!vm.redisKeys.contains(key))
        let exists = try await other.query("EXISTS", params: [.string(key)])
        #expect(rkText(rkCell(exists, 0, 0)) == "0")
        await vm.disconnect()
    }

    // MARK: - 命名空间键树聚合

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func namespaceTreeAggregation() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        // 前缀不含冒号，确保它本身是键树的顶层分支节点。
        let prefix = "p43e\(UUID().uuidString.prefix(8))"
        let keys = ["\(prefix):ns1:a", "\(prefix):ns1:b", "\(prefix):ns2:c"]
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: keys); await other.close() } }
        for k in keys { _ = try await other.execute("SET", params: [.string(k), .string("v")]) }
        await connect(vm, port: port)
        await vm.loadRedisKeys()
        // 顶层应有一个以 prefix 命名的分支节点，聚合 3 个叶子。
        let top = try #require(vm.redisKeyTree.first { $0.name == prefix })
        #expect(top.fullKey == nil)
        #expect(top.keyCount == 3)
        let ns1 = try #require(top.children.first { $0.name == "ns1" })
        #expect(ns1.keyCount == 2)
        #expect(ns1.children.contains { $0.fullKey == "\(prefix):ns1:a" })
        #expect(ns1.children.contains { $0.fullKey == "\(prefix):ns1:b" })
        let ns2 = try #require(top.children.first { $0.name == "ns2" })
        #expect(ns2.keyCount == 1)
        await vm.disconnect()
    }

    // MARK: - SCAN 分页（解除一次性上限）

    @Test(.enabled(if: rkPort("LODE_TEST_REDIS_PORT") != nil))
    func scanPagingDrainsAllKeys() async throws {
        let port = try #require(rkPort("LODE_TEST_REDIS_PORT"))
        let prefix = "p43e:\(UUID().uuidString.prefix(8))"
        let total = 1200
        let keys = (0..<total).map { "\(prefix):page:\($0)" }
        let vm = await makeSUT()
        let other = try await RedisConnection(host: "127.0.0.1", port: port)
        defer { Task { await cleanup(other, keys: keys); await other.close() } }
        // 批量建键（每条 SET 一个键），用 pipeline 逐条下发。
        for k in keys { _ = try await other.execute("SET", params: [.string(k), .string("v")]) }
        await connect(vm, port: port)
        await vm.loadRedisKeys()
        // 首页累计到页目标（1000）即停，总量超过目标时仍有后续页。
        #expect(vm.redisKeys.count >= 1000)
        #expect(vm.redisHasMoreKeys)
        var guard_ = 0
        while vm.redisHasMoreKeys && guard_ < 100 {
            await vm.loadMoreRedisKeys()
            guard_ += 1
        }
        #expect(!vm.redisHasMoreKeys)
        let loaded = Set(vm.redisKeys)
        #expect(keys.allSatisfy { loaded.contains($0) })
        await vm.disconnect()
    }
}