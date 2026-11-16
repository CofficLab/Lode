import Foundation

/// Redis 键的数据类型，对应 `TYPE` 命令的返回值。
public enum RedisKeyType: String, Sendable, CaseIterable, Equatable {
    case string
    case hash
    case list
    case set
    case zset
    case stream
    /// 键不存在（TYPE 返回 "none"）。
    case none
    /// 无法识别的类型（模块自定义类型等），保守归一。
    case unknown

    /// 由 TYPE 命令的原始字符串构造；未知值归 ``unknown``。
    public init(commandResult raw: String) {
        self = RedisKeyType(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unknown
    }

    public var displayTitle: String {
        switch self {
        case .string: return "String"
        case .hash: return "Hash"
        case .list: return "List"
        case .set: return "Set"
        case .zset: return "Sorted Set"
        case .stream: return "Stream"
        case .none: return "None"
        case .unknown: return "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .string: return "textformat"
        case .hash: return "tablecells"
        case .list: return "list.bullet"
        case .set: return "circle.grid.2x2"
        case .zset: return "list.number"
        case .stream: return "waveform"
        case .none: return "questionmark"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// 键元信息：类型 + TTL（秒）。`ttl == -1` 表示永不过期，`-2` 表示键已不存在。
public struct RedisKeyInfo: Sendable, Equatable, Identifiable {
    public var key: String
    public var type: RedisKeyType
    public var ttl: Int

    public init(key: String, type: RedisKeyType, ttl: Int) {
        self.key = key
        self.type = type
        self.ttl = ttl
    }

    public var id: String { key }
    public var hasExpiry: Bool { ttl >= 0 }
}

/// 命名空间键树节点：按分隔符（默认 `:`）聚合扁平键列表得到的折叠树。
/// 分支节点 ``fullKey`` 为 nil；叶子节点携带完整键名。
public struct RedisKeyTreeNode: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var fullKey: String?
    public var children: [RedisKeyTreeNode]
    /// 子树内叶子键的数量（含本节点若为叶子）。
    public var keyCount: Int

    public init(id: String, name: String, fullKey: String?, children: [RedisKeyTreeNode], keyCount: Int) {
        self.id = id
        self.name = name
        self.fullKey = fullKey
        self.children = children
        self.keyCount = keyCount
    }

    public var isLeaf: Bool { fullKey != nil }

    /// OutlineGroup 的子节点键路径：无子节点返回 nil（纯叶子），有子节点则可展开。
    /// 「既是叶子又是分支」的节点（a 与 a:b 共存）仍可展开，同时整行可点击打开键 a。
    public var outlineChildren: [RedisKeyTreeNode]? { children.isEmpty ? nil : children }
}

/// 把扁平键列表聚合成命名空间树（纯函数，确定性排序，便于快照测试）。
public enum RedisKeyTreeBuilder {
    public static func build(keys: [String], separator: String = ":") -> [RedisKeyTreeNode] {
        final class Trie {
            var children: [String: Trie] = [:]
            var fullKey: String?
        }

        let root = Trie()
        // 去重，避免重复键产生重复叶子。
        for key in Set(keys) {
            var node = root
            for part in key.components(separatedBy: separator) {
                if let existing = node.children[part] {
                    node = existing
                } else {
                    let child = Trie()
                    node.children[part] = child
                    node = child
                }
            }
            node.fullKey = key
        }

        func convert(_ trie: Trie, name: String, path: String) -> RedisKeyTreeNode {
            let children = trie.children
                .map { childName, childTrie -> RedisKeyTreeNode in
                    let childPath = path.isEmpty ? childName : path + separator + childName
                    return convert(childTrie, name: childName, path: childPath)
                }
                .sorted { lhs, rhs in
                    // 分支（命名空间）排在叶子键之前，组内按名称升序，保证确定性。
                    if lhs.isLeaf != rhs.isLeaf { return !lhs.isLeaf }
                    return lhs.name < rhs.name
                }
            let selfLeaf = trie.fullKey != nil ? 1 : 0
            let count = selfLeaf + children.reduce(0) { $0 + $1.keyCount }
            return RedisKeyTreeNode(
                id: path,
                name: name,
                fullKey: trie.fullKey,
                children: children,
                keyCount: count
            )
        }

        return root.children
            .map { name, trie in convert(trie, name: name, path: name) }
            .sorted { lhs, rhs in
                if lhs.isLeaf != rhs.isLeaf { return !lhs.isLeaf }
                return lhs.name < rhs.name
            }
    }
}

/// Hash 字段 / Stream 字段键值对。
public struct RedisHashEntry: Sendable, Equatable {
    public var field: String
    public var value: DatabaseValue

    public init(field: String, value: DatabaseValue) {
        self.field = field
        self.value = value
    }
}

/// Sorted Set 成员及其分数。
public struct RedisZSetEntry: Sendable, Equatable {
    public var member: DatabaseValue
    public var score: Double

    public init(member: DatabaseValue, score: Double) {
        self.member = member
        self.score = score
    }
}

/// Stream 条目：ID + 字段键值对。
public struct RedisStreamEntry: Sendable, Equatable {
    public var id: String
    public var fields: [RedisHashEntry]

    public init(id: String, fields: [RedisHashEntry]) {
        self.id = id
        self.fields = fields
    }
}

/// 类型化的键值，供查看/编辑器按类型渲染。
public enum RedisKeyValue: Sendable, Equatable {
    case string(DatabaseValue)
    case hash([RedisHashEntry])
    case list([DatabaseValue])
    case set([DatabaseValue])
    case zset([RedisZSetEntry])
    case stream([RedisStreamEntry])

    /// 由驱动整形后的 ``QueryResult`` 还原类型化值。
    /// 列约定：HGETALL=Field/Value，ZRANGE WITHSCORES=Member/Score，XRANGE=ID/Field/Value。
    public static func from(type: RedisKeyType, result: QueryResult) -> RedisKeyValue {
        func column(_ row: [DatabaseValue], _ index: Int) -> DatabaseValue {
            index < row.count ? row[index] : .null
        }
        func text(_ value: DatabaseValue) -> String {
            if case .string(let s) = value { return s }
            return value.description
        }
        func score(_ value: DatabaseValue) -> Double {
            switch value {
            case .double(let d): return d
            case .integer(let i): return Double(i)
            case .string(let s): return Double(s) ?? 0
            default: return 0
            }
        }

        switch type {
        case .string:
            // GET 整形为 Key/Value 两列，值在第 1 列。
            let value = result.rows.first.map { column($0, 1) } ?? .null
            return .string(value)
        case .hash:
            return .hash(result.rows.map { RedisHashEntry(field: text(column($0, 0)), value: column($0, 1)) })
        case .list:
            return .list(result.rows.map { column($0, 0) })
        case .set:
            return .set(result.rows.map { column($0, 0) })
        case .zset:
            return .zset(result.rows.map { RedisZSetEntry(member: column($0, 0), score: score(column($0, 1))) })
        case .stream:
            var entries: [RedisStreamEntry] = []
            for row in result.rows {
                let id = text(column(row, 0))
                let field = RedisHashEntry(field: text(column(row, 1)), value: column(row, 2))
                if let last = entries.last, last.id == id {
                    entries[entries.count - 1].fields.append(field)
                } else {
                    entries.append(RedisStreamEntry(id: id, fields: [field]))
                }
            }
            return .stream(entries)
        case .none, .unknown:
            return .string(.null)
        }
    }
}

/// 类型化键的读取命令映射（纯函数）。
///
/// 键与动态参数一律经 ``DatabaseConnection/query(_:params:)`` 的 params 通道传入，
/// 由驱动按字面量拼接，避免键名含空格/引号时的转义与注入问题。
public enum RedisKeyCommands {
    /// 返回类型对应的读取命令与参数；键不存在/未知类型返回 nil（无可读值）。
    public static func read(type: RedisKeyType, key: String) -> (command: String, params: [DatabaseValue])? {
        switch type {
        case .string: return ("GET", [.string(key)])
        case .hash: return ("HGETALL", [.string(key)])
        case .list: return ("LRANGE", [.string(key), .string("0"), .string("-1")])
        case .set: return ("SMEMBERS", [.string(key)])
        case .zset: return ("ZRANGE", [.string(key), .string("0"), .string("-1"), .string("WITHSCORES")])
        case .stream: return ("XRANGE", [.string(key), .string("-"), .string("+")])
        case .none, .unknown: return nil
        }
    }
}

/// 类型化键编辑操作（纯模型）：把 UI 意图映射为 Redis 写命令 + 参数。
///
/// 所有 case 均为写操作，VM 经写闸门（confirmWrites 确认 / readOnly 拒绝）后执行。
/// 命令字符串只含动词，键/字段/值/分数经 params 通道传入，杜绝注入。
public enum RedisKeyEdit: Sendable, Equatable {
    case setString(key: String, value: String)
    case setTTL(key: String, seconds: Int)
    case persist(key: String)
    case delete(key: String)
    case hashSet(key: String, field: String, value: String)
    case hashDelete(key: String, field: String)
    case listPush(key: String, value: String)
    case listSet(key: String, index: Int, value: String)
    /// 按值移除列表元素（LREM count 0：移除所有匹配项）。
    case listRemove(key: String, value: String)
    case setAdd(key: String, member: String)
    case setRemove(key: String, member: String)
    case zsetAdd(key: String, member: String, score: Double)
    case zsetRemove(key: String, member: String)
    /// 追加 Stream 条目（XADD key * field value …，ID 自动生成）。
    case streamAdd(key: String, fields: [RedisHashEntry])
    case streamDelete(key: String, id: String)

    public var key: String {
        switch self {
        case .setString(let key, _), .setTTL(let key, _), .persist(let key), .delete(let key),
             .hashSet(let key, _, _), .hashDelete(let key, _),
             .listPush(let key, _), .listSet(let key, _, _), .listRemove(let key, _),
             .setAdd(let key, _), .setRemove(let key, _),
             .zsetAdd(let key, _, _), .zsetRemove(let key, _),
             .streamAdd(let key, _), .streamDelete(let key, _):
            return key
        }
    }

    /// 命令动词（写闸门按动词判定 Redis 写）。
    public var command: String {
        switch self {
        case .setString: return "SET"
        case .setTTL: return "EXPIRE"
        case .persist: return "PERSIST"
        case .delete: return "DEL"
        case .hashSet: return "HSET"
        case .hashDelete: return "HDEL"
        case .listPush: return "RPUSH"
        case .listSet: return "LSET"
        case .listRemove: return "LREM"
        case .setAdd: return "SADD"
        case .setRemove: return "SREM"
        case .zsetAdd: return "ZADD"
        case .zsetRemove: return "ZREM"
        case .streamAdd: return "XADD"
        case .streamDelete: return "XDEL"
        }
    }

    /// 动词之后的动态参数（键优先，随后按命令语义排列）。
    public var params: [DatabaseValue] {
        switch self {
        case .setString(let key, let value):
            return [.string(key), .string(value)]
        case .setTTL(let key, let seconds):
            return [.string(key), .integer(seconds)]
        case .persist(let key), .delete(let key):
            return [.string(key)]
        case .hashSet(let key, let field, let value):
            return [.string(key), .string(field), .string(value)]
        case .hashDelete(let key, let field):
            return [.string(key), .string(field)]
        case .listPush(let key, let value):
            return [.string(key), .string(value)]
        case .listSet(let key, let index, let value):
            return [.string(key), .integer(index), .string(value)]
        case .listRemove(let key, let value):
            return [.string(key), .integer(0), .string(value)]
        case .setAdd(let key, let member), .setRemove(let key, let member):
            return [.string(key), .string(member)]
        case .zsetAdd(let key, let member, let score):
            return [.string(key), .double(score), .string(member)]
        case .zsetRemove(let key, let member):
            return [.string(key), .string(member)]
        case .streamAdd(let key, let fields):
            return [.string(key), .string("*")] + fields.flatMap { [.string($0.field), $0.value] }
        case .streamDelete(let key, let id):
            return [.string(key), .string(id)]
        }
    }
}