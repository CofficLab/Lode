import Foundation
import Testing
@testable import DatabaseManagerPlugin

/// 类型化键读取/编辑命令的纯映射：命令动词、参数顺序、键提取、写闸门一致性。
struct RedisKeyCommandsTests {
    // MARK: - 读取映射

    @Test("每个类型的读取命令与参数")
    func readCommandPerType() throws {
        let key = "k"
        let string = try #require(RedisKeyCommands.read(type: .string, key: key))
        #expect(string.command == "GET")
        #expect(string.params == [.string(key)])

        let hash = try #require(RedisKeyCommands.read(type: .hash, key: key))
        #expect(hash.command == "HGETALL")
        #expect(hash.params == [.string(key)])

        let list = try #require(RedisKeyCommands.read(type: .list, key: key))
        #expect(list.command == "LRANGE")
        #expect(list.params == [.string(key), .string("0"), .string("-1")])

        let set = try #require(RedisKeyCommands.read(type: .set, key: key))
        #expect(set.command == "SMEMBERS")
        #expect(set.params == [.string(key)])

        let zset = try #require(RedisKeyCommands.read(type: .zset, key: key))
        #expect(zset.command == "ZRANGE")
        #expect(zset.params == [.string(key), .string("0"), .string("-1"), .string("WITHSCORES")])

        let stream = try #require(RedisKeyCommands.read(type: .stream, key: key))
        #expect(stream.command == "XRANGE")
        #expect(stream.params == [.string(key), .string("-"), .string("+")])
    }

    @Test("键不存在/未知类型无可读值")
    func readNoneReturnsNil() {
        #expect(RedisKeyCommands.read(type: .none, key: "k") == nil)
        #expect(RedisKeyCommands.read(type: .unknown, key: "k") == nil)
    }

    // MARK: - 编辑映射

    private var allEdits: [RedisKeyEdit] {
        [
            .setString(key: "k", value: "v"),
            .setTTL(key: "k", seconds: 10),
            .persist(key: "k"),
            .delete(key: "k"),
            .hashSet(key: "k", field: "f", value: "v"),
            .hashDelete(key: "k", field: "f"),
            .listPush(key: "k", value: "v"),
            .listSet(key: "k", index: 2, value: "v"),
            .listRemove(key: "k", value: "v"),
            .setAdd(key: "k", member: "m"),
            .setRemove(key: "k", member: "m"),
            .zsetAdd(key: "k", member: "m", score: 1.5),
            .zsetRemove(key: "k", member: "m"),
            .streamAdd(key: "k", fields: [RedisHashEntry(field: "f", value: .string("v"))]),
            .streamDelete(key: "k", id: "1-0"),
        ]
    }

    @Test("每个编辑映射到正确的命令动词")
    func editCommandVerbs() {
        let expected = ["SET", "EXPIRE", "PERSIST", "DEL", "HSET", "HDEL", "RPUSH",
                        "LSET", "LREM", "SADD", "SREM", "ZADD", "ZREM", "XADD", "XDEL"]
        #expect(allEdits.map(\.command) == expected)
    }

    @Test("每个编辑都提取出目标键")
    func editKeyExtraction() {
        #expect(allEdits.allSatisfy { $0.key == "k" })
    }

    @Test("所有编辑命令都被写闸门判为写")
    func allEditsAreWrites() {
        for edit in allEdits {
            #expect(WriteGate.isWriteStatement(edit.command, type: .redis), "edit not gated as write: \(edit.command)")
        }
    }

    @Test("代表性编辑的参数顺序")
    func editParams() {
        #expect(RedisKeyEdit.setString(key: "k", value: "v").params == [.string("k"), .string("v")])
        #expect(RedisKeyEdit.setTTL(key: "k", seconds: 10).params == [.string("k"), .integer(10)])
        #expect(RedisKeyEdit.persist(key: "k").params == [.string("k")])
        #expect(RedisKeyEdit.delete(key: "k").params == [.string("k")])
        #expect(RedisKeyEdit.hashSet(key: "k", field: "f", value: "v").params == [.string("k"), .string("f"), .string("v")])
        #expect(RedisKeyEdit.hashDelete(key: "k", field: "f").params == [.string("k"), .string("f")])
        #expect(RedisKeyEdit.listSet(key: "k", index: 2, value: "v").params == [.string("k"), .integer(2), .string("v")])
        #expect(RedisKeyEdit.listRemove(key: "k", value: "v").params == [.string("k"), .integer(0), .string("v")])
        #expect(RedisKeyEdit.zsetAdd(key: "k", member: "m", score: 1.5).params == [.string("k"), .double(1.5), .string("m")])
        #expect(RedisKeyEdit.zsetRemove(key: "k", member: "m").params == [.string("k"), .string("m")])
        #expect(RedisKeyEdit.streamDelete(key: "k", id: "1-0").params == [.string("k"), .string("1-0")])
    }

    @Test("XADD 展平字段为 key * field value …")
    func streamAddFlattensFields() {
        let edit = RedisKeyEdit.streamAdd(key: "k", fields: [
            RedisHashEntry(field: "f1", value: .string("v1")),
            RedisHashEntry(field: "f2", value: .integer(2)),
        ])
        #expect(edit.command == "XADD")
        #expect(edit.params == [.string("k"), .string("*"), .string("f1"), .string("v1"), .string("f2"), .integer(2)])
    }

    @Test("含空格/引号的键经 params 原样传递（不拼接进命令字符串）")
    func keysWithSpacesStayInParams() {
        let tricky = "a b\"c'd"
        let edit = RedisKeyEdit.setString(key: tricky, value: "v")
        #expect(edit.command == "SET")
        #expect(edit.params.first == .string(tricky))
        let read = RedisKeyCommands.read(type: .string, key: tricky)
        #expect(read?.params == [.string(tricky)])
    }
}