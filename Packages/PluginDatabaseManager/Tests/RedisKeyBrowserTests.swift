import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// Redis 类型化键浏览的纯逻辑：命名空间树聚合、TYPE 解析、RESP 结果整形、类型化值还原。
struct RedisKeyBrowserTests {
    // MARK: - RedisKeyType

    @Test("TYPE 原始值解析（大小写/空白/未知）")
    func typeParsing() {
        #expect(RedisKeyType(commandResult: "string") == .string)
        #expect(RedisKeyType(commandResult: "HASH") == .hash)
        #expect(RedisKeyType(commandResult: " zset ") == .zset)
        #expect(RedisKeyType(commandResult: "stream") == .stream)
        #expect(RedisKeyType(commandResult: "none") == .none)
        #expect(RedisKeyType(commandResult: "module-x") == .unknown)
    }

    @Test("每个类型有展示名与图标")
    func typeDisplay() {
        for type in RedisKeyType.allCases {
            #expect(!type.displayTitle.isEmpty)
            #expect(!type.systemImage.isEmpty)
        }
    }

    // MARK: - 命名空间树

    @Test("无分隔符的键成为顶层叶子，按名升序")
    func flatKeys() {
        let tree = RedisKeyTreeBuilder.build(keys: ["beta", "alpha", "gamma"])
        #expect(tree.map(\.name) == ["alpha", "beta", "gamma"])
        #expect(tree.allSatisfy { $0.isLeaf && $0.children.isEmpty && $0.keyCount == 1 })
        #expect(tree.first?.fullKey == "alpha")
    }

    @Test("按 : 聚合命名空间，keyCount 统计子树叶子")
    func nestedNamespaces() throws {
        let tree = RedisKeyTreeBuilder.build(keys: ["user:1:name", "user:1:age", "user:2:name", "cache:x"])
        #expect(tree.map(\.name) == ["cache", "user"])  // 分支按名升序
        let user = try #require(tree.first { $0.name == "user" })
        #expect(user.isLeaf == false)
        #expect(user.keyCount == 3)
        #expect(user.children.map(\.name) == ["1", "2"])
        let one = try #require(user.children.first { $0.name == "1" })
        #expect(one.keyCount == 2)
        #expect(one.children.map(\.fullKey) == ["user:1:age", "user:1:name"])
    }

    @Test("分支排在叶子键之前")
    func branchesBeforeLeaves() {
        let tree = RedisKeyTreeBuilder.build(keys: ["zleaf", "a:1", "aleaf"])
        // 分支 "a" 先于叶子 "aleaf"/"zleaf"。
        #expect(tree.map(\.name) == ["a", "aleaf", "zleaf"])
        #expect(tree[0].isLeaf == false)
    }

    @Test("重复键去重")
    func deduplicates() {
        let tree = RedisKeyTreeBuilder.build(keys: ["a", "a", "a"])
        #expect(tree.count == 1)
        #expect(tree[0].keyCount == 1)
    }

    @Test("既是叶子又是分支的键（a 与 a:b 共存）")
    func leafAndBranchCoexist() throws {
        let tree = RedisKeyTreeBuilder.build(keys: ["a", "a:b"])
        let a = try #require(tree.first { $0.name == "a" })
        #expect(a.isLeaf)
        #expect(a.fullKey == "a")
        #expect(a.keyCount == 2)  // 自身 + a:b
        #expect(a.children.map(\.fullKey) == ["a:b"])
    }

    @Test("自定义分隔符")
    func customSeparator() {
        let tree = RedisKeyTreeBuilder.build(keys: ["a/b", "a/c"], separator: "/")
        #expect(tree.map(\.name) == ["a"])
        #expect(tree[0].children.map(\.name) == ["b", "c"])
    }

    @Test("空输入产生空树")
    func emptyInput() {
        #expect(RedisKeyTreeBuilder.build(keys: []).isEmpty)
    }

    // MARK: - RESP 整形

    private func bulk(_ s: String) -> RespValue { .bulkString(Data(s.utf8)) }

    @Test("GET 整形为 Key/Value")
    func shapeGet() throws {
        let result = try RedisQueryResultShaper.shape(command: "GET", args: ["GET", "k"], response: bulk("v"))
        #expect(result.columns == ["Key", "Value"])
        #expect(result.rows == [[.string("k"), .string("v")]])
    }

    @Test("GET 空值（null bulk）→ NULL")
    func shapeGetNull() throws {
        let result = try RedisQueryResultShaper.shape(command: "GET", args: ["GET", "k"], response: .bulkString(nil))
        #expect(result.rows == [[.string("k"), .null]])
    }

    @Test("SCAN 保持 Key 单列（Agent 兼容）")
    func shapeScan() throws {
        let resp = RespValue.array([bulk("17"), .array([bulk("a"), bulk("b")])])
        let result = try RedisQueryResultShaper.shape(command: "SCAN", args: ["SCAN", "0"], response: resp)
        #expect(result.columns == ["Key"])
        #expect(result.rows == [[.string("a")], [.string("b")]])
    }

    @Test("TYPE / TTL 标量整形")
    func shapeTypeAndTTL() throws {
        let type = try RedisQueryResultShaper.shape(command: "TYPE", args: ["TYPE", "k"], response: .simpleString("hash"))
        #expect(type.columns == ["Type"])
        #expect(type.rows == [[.string("hash")]])
        let ttl = try RedisQueryResultShaper.shape(command: "TTL", args: ["TTL", "k"], response: .integer(-1))
        #expect(ttl.columns == ["TTL"])
        #expect(ttl.rows == [[.integer(-1)]])
    }

    @Test("HGETALL 保留字段/值配对")
    func shapeHGetAll() throws {
        let resp = RespValue.array([bulk("f1"), bulk("v1"), bulk("f2"), bulk("v2")])
        let result = try RedisQueryResultShaper.shape(command: "HGETALL", args: ["HGETALL", "h"], response: resp)
        #expect(result.columns == ["Field", "Value"])
        #expect(result.rows == [[.string("f1"), .string("v1")], [.string("f2"), .string("v2")]])
    }

    @Test("HGETALL 空哈希 → 零行")
    func shapeHGetAllEmpty() throws {
        let result = try RedisQueryResultShaper.shape(command: "HGETALL", args: ["HGETALL", "h"], response: .array([]))
        #expect(result.rows.isEmpty)
    }

    @Test("ZRANGE WITHSCORES 保留成员/分数")
    func shapeZRangeWithScores() throws {
        let resp = RespValue.array([bulk("m1"), bulk("1.5"), bulk("m2"), bulk("2")])
        let result = try RedisQueryResultShaper.shape(
            command: "ZRANGE", args: ["ZRANGE", "z", "0", "-1", "WITHSCORES"], response: resp)
        #expect(result.columns == ["Member", "Score"])
        #expect(result.rows == [[.string("m1"), .string("1.5")], [.string("m2"), .string("2")]])
    }

    @Test("ZRANGE 无 WITHSCORES 仅成员列")
    func shapeZRangeNoScores() throws {
        let resp = RespValue.array([bulk("m1"), bulk("m2")])
        let result = try RedisQueryResultShaper.shape(command: "ZRANGE", args: ["ZRANGE", "z", "0", "-1"], response: resp)
        #expect(result.columns == ["Member"])
        #expect(result.rows == [[.string("m1")], [.string("m2")]])
    }

    @Test("LRANGE / SMEMBERS 单列保序")
    func shapeListAndSet() throws {
        let resp = RespValue.array([bulk("a"), bulk("b"), bulk("c")])
        let list = try RedisQueryResultShaper.shape(command: "LRANGE", args: ["LRANGE", "l", "0", "-1"], response: resp)
        #expect(list.columns == ["Value"])
        #expect(list.rows == [[.string("a")], [.string("b")], [.string("c")]])
        let set = try RedisQueryResultShaper.shape(command: "SMEMBERS", args: ["SMEMBERS", "s"], response: resp)
        #expect(set.columns == ["Value"])
        #expect(set.rows.count == 3)
    }

    @Test("XRANGE 展开条目为 ID/Field/Value")
    func shapeXRange() throws {
        let entry = RespValue.array([bulk("1-0"), .array([bulk("f1"), bulk("v1"), bulk("f2"), bulk("v2")])])
        let resp = RespValue.array([entry])
        let result = try RedisQueryResultShaper.shape(command: "XRANGE", args: ["XRANGE", "s", "-", "+"], response: resp)
        #expect(result.columns == ["ID", "Field", "Value"])
        #expect(result.rows == [
            [.string("1-0"), .string("f1"), .string("v1")],
            [.string("1-0"), .string("f2"), .string("v2")],
        ])
    }

    @Test("非 UTF8 bulk → data")
    func shapeBinary() throws {
        let bytes = Data([0xFF, 0xFE, 0x00])
        let result = try RedisQueryResultShaper.shape(command: "GET", args: ["GET", "k"], response: .bulkString(bytes))
        #expect(result.rows == [[.string("k"), .data(bytes)]])
    }

    @Test("默认路径错误响应抛错")
    func shapeErrorThrows() {
        #expect(throws: DatabaseError.self) {
            _ = try RedisQueryResultShaper.shape(command: "SET", args: ["SET", "k", "v"], response: .error("ERR bad"))
        }
    }

    // MARK: - 类型化值还原

    @Test("string 值从 GET 结果还原")
    func valueFromString() {
        let result = QueryResult(columns: ["Key", "Value"], rows: [[.string("k"), .string("hello")]], rowsAffected: 0)
        #expect(RedisKeyValue.from(type: .string, result: result) == .string(.string("hello")))
    }

    @Test("hash 值从 Field/Value 还原")
    func valueFromHash() {
        let result = QueryResult(columns: ["Field", "Value"], rows: [[.string("f"), .string("v")]], rowsAffected: 0)
        #expect(RedisKeyValue.from(type: .hash, result: result) == .hash([RedisHashEntry(field: "f", value: .string("v"))]))
    }

    @Test("zset 分数从字符串解析为 Double")
    func valueFromZSet() {
        let result = QueryResult(columns: ["Member", "Score"], rows: [[.string("m"), .string("1.5")]], rowsAffected: 0)
        #expect(RedisKeyValue.from(type: .zset, result: result) == .zset([RedisZSetEntry(member: .string("m"), score: 1.5)]))
    }

    @Test("stream 按 ID 聚合字段")
    func valueFromStream() {
        let result = QueryResult(columns: ["ID", "Field", "Value"], rows: [
            [.string("1-0"), .string("a"), .string("1")],
            [.string("1-0"), .string("b"), .string("2")],
            [.string("2-0"), .string("c"), .string("3")],
        ], rowsAffected: 0)
        let value = RedisKeyValue.from(type: .stream, result: result)
        guard case .stream(let entries) = value else {
            Issue.record("expected stream")
            return
        }
        #expect(entries.count == 2)
        #expect(entries[0].id == "1-0")
        #expect(entries[0].fields.count == 2)
        #expect(entries[1].fields == [RedisHashEntry(field: "c", value: .string("3"))])
    }
}