import Foundation

/// 把 Redis 命令的 RESP 响应整形为 ``QueryResult``（纯函数，便于离线单测）。
///
/// 通用路径会把数组拍平成单列，丢失 HGETALL 的字段/值配对、ZRANGE 的分数、
/// XRANGE 的条目结构；这里为类型化浏览保留这些结构。GET/SCAN 与默认路径
/// 保持既有行为不变（SCAN 的 `["Key"]` 形状被 Agent 工具消费，不可更改）。
enum RedisQueryResultShaper {
    static func shape(command: String, args: [String], response: RespValue) throws -> QueryResult {
        switch command {
        case "GET":
            let key = args.count > 1 ? args[1] : ""
            let value: DatabaseValue
            switch response {
            case .bulkString(let data):
                value = RedisValueConverter.databaseValue(fromBulkString: data)
            case .simpleString(let string):
                value = .string(string)
            case .integer(let integer):
                value = .integer(integer)
            case .error(let error):
                throw DatabaseError.queryFailed(error)
            default:
                value = .string("\(response)")
            }
            return QueryResult(columns: ["Key", "Value"], rows: [[.string(key), value]], rowsAffected: 0)

        case "SCAN":
            var keys: [String] = []
            if case .array(let outer?) = response,
               outer.count >= 2,
               case .array(let inner?) = outer[1] {
                keys = inner.compactMap { value in
                    if case .bulkString(let data?) = value {
                        return String(data: data, encoding: .utf8)
                    }
                    return nil
                }
            }
            return QueryResult(columns: ["Key"], rows: keys.map { [.string($0)] }, rowsAffected: 0)

        case "TYPE":
            return QueryResult(columns: ["Type"], rows: [[.string(text(response))]], rowsAffected: 0)

        case "TTL", "PTTL":
            if case .integer(let n) = response {
                return QueryResult(columns: ["TTL"], rows: [[.integer(n)]], rowsAffected: 0)
            }
            return QueryResult(columns: ["TTL"], rows: [[scalar(response)]], rowsAffected: 0)

        case "HGETALL":
            return pairedRows(response: response, columns: ["Field", "Value"], fieldIsText: true)

        case "HKEYS":
            return singleColumn(response: response, column: "Field", asText: true)

        case "HVALS", "LRANGE", "SMEMBERS":
            return singleColumn(response: response, column: "Value", asText: false)

        case "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX":
            let withScores = args.contains { $0.uppercased() == "WITHSCORES" }
            if withScores {
                return pairedRows(response: response, columns: ["Member", "Score"], fieldIsText: false)
            }
            return singleColumn(response: response, column: "Member", asText: false)

        case "XRANGE", "XREVRANGE":
            return streamRows(response: response)

        default:
            switch response {
            case .array(let values):
                return QueryResult(columns: ["Value"], rows: flatten(values ?? []).map { [$0] }, rowsAffected: 0)
            case .bulkString(let data):
                return QueryResult(columns: ["Value"], rows: [[RedisValueConverter.databaseValue(fromBulkString: data)]], rowsAffected: 0)
            case .simpleString(let value):
                return QueryResult(columns: ["Value"], rows: [[.string(value)]], rowsAffected: 0)
            case .integer(let value):
                return QueryResult(columns: ["Value"], rows: [[.integer(value)]], rowsAffected: 0)
            case .error(let error):
                throw DatabaseError.queryFailed(error)
            }
        }
    }

    // MARK: - Helpers

    private static func scalar(_ resp: RespValue) -> DatabaseValue {
        switch resp {
        case .bulkString(let data):
            return RedisValueConverter.databaseValue(fromBulkString: data)
        case .simpleString(let s):
            return .string(s)
        case .integer(let i):
            return .integer(i)
        case .error(let e):
            return .string("ERR: \(e)")
        case .array:
            return .string("\(resp)")
        }
    }

    private static func text(_ resp: RespValue) -> String {
        switch resp {
        case .bulkString(let data?):
            return String(data: data, encoding: .utf8) ?? ""
        case .simpleString(let s):
            return s
        case .integer(let i):
            return String(i)
        default:
            return ""
        }
    }

    private static func flatten(_ values: [RespValue]) -> [DatabaseValue] {
        var result: [DatabaseValue] = []
        for value in values {
            if case .array(let nested) = value {
                result.append(contentsOf: flatten(nested ?? []))
            } else {
                result.append(scalar(value))
            }
        }
        return result
    }

    /// 交替排列的数组 → 两列行（HGETALL 字段/值、ZRANGE WITHSCORES 成员/分数）。
    private static func pairedRows(response: RespValue, columns: [String], fieldIsText: Bool) -> QueryResult {
        guard case .array(let values?) = response else {
            return QueryResult(columns: columns, rows: [], rowsAffected: 0)
        }
        var rows: [[DatabaseValue]] = []
        var i = 0
        while i + 1 < values.count {
            let first: DatabaseValue = fieldIsText ? .string(text(values[i])) : scalar(values[i])
            rows.append([first, scalar(values[i + 1])])
            i += 2
        }
        return QueryResult(columns: columns, rows: rows, rowsAffected: 0)
    }

    private static func singleColumn(response: RespValue, column: String, asText: Bool) -> QueryResult {
        guard case .array(let values?) = response else {
            return QueryResult(columns: [column], rows: [], rowsAffected: 0)
        }
        let rows: [[DatabaseValue]] = values.map { [asText ? .string(text($0)) : scalar($0)] }
        return QueryResult(columns: [column], rows: rows, rowsAffected: 0)
    }

    /// XRANGE/XREVRANGE：每个条目 `[id, [field, value, ...]]` → ID/Field/Value 行。
    private static func streamRows(response: RespValue) -> QueryResult {
        let columns = ["ID", "Field", "Value"]
        guard case .array(let entries?) = response else {
            return QueryResult(columns: columns, rows: [], rowsAffected: 0)
        }
        var rows: [[DatabaseValue]] = []
        for entry in entries {
            guard case .array(let parts?) = entry, parts.count >= 2 else { continue }
            let id = text(parts[0])
            guard case .array(let fields?) = parts[1] else { continue }
            var j = 0
            while j + 1 < fields.count {
                rows.append([.string(id), .string(text(fields[j])), scalar(fields[j + 1])])
                j += 2
            }
        }
        return QueryResult(columns: columns, rows: rows, rowsAffected: 0)
    }
}