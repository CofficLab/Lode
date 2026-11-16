import Foundation

#if canImport(PostgresNIO)
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

public final class PostgreSQLDriver: DatabaseDriver, Sendable {
    public var type: DatabaseType { .postgresql }

    public init() {}

    public func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        guard let host = config.host, !host.isEmpty else {
            throw DatabaseError.invalidConfiguration("PostgreSQL 需要有效的主机地址")
        }
        let port = try config.validatedNetworkPort(serviceName: "PostgreSQL")
        guard !config.database.isEmpty else {
            throw DatabaseError.invalidConfiguration("PostgreSQL 需要指定数据库名")
        }
        guard let user = config.username, !user.isEmpty else {
            throw DatabaseError.invalidConfiguration("PostgreSQL 需要用户名")
        }

        return try await PGConnection(
            host: host,
            port: port,
            username: user,
            password: config.password,
            database: config.database,
            sslOption: config.sslOption,
            tlsConfig: config.tlsConfig,
            connectTimeoutSeconds: config.connectTimeoutSeconds
        )
    }
}

public actor PGConnection: DatabaseConnection {
    private let group: EventLoopGroup
    private let conn: PostgresConnection
    private let logger = Logger(label: "com.lumi.postgres")
    private let cancelContext: CancelContext
    private var backendPID: Int?

    private struct CancelContext: Sendable {
        let host: String
        let port: Int
        let username: String
        let password: String?
        let database: String
        let sslOption: ConnectionSSLOption?
        let tlsConfig: ConnectionTLSConfig?
    }

    public init(host: String, port: Int, username: String, password: String?, database: String, sslOption: ConnectionSSLOption? = nil, tlsConfig: ConnectionTLSConfig? = nil, connectTimeoutSeconds: Int = 10) async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        cancelContext = CancelContext(
            host: host, port: port, username: username,
            password: password, database: database, sslOption: sslOption, tlsConfig: tlsConfig
        )

        do {
            var config = PostgresConnection.Configuration(
                host: host,
                port: port,
                username: username,
                password: password ?? "",
                database: database,
                tls: try Self.makeTLS(sslOption, tls: tlsConfig)
            )
            // 原生 connectTimeout 设为极大值，把超时裁决统一交给 ConnectTimeout.race，
            // 避免默认 10s 与可配超时（含 0=不限制）相互干扰。
            config.options.connectTimeout = .hours(24 * 365)

            let future: EventLoopFuture<PostgresConnection> = PostgresConnection.connect(
                on: group.next(),
                configuration: config,
                id: 1,
                logger: logger
            )
            let raced = ConnectTimeout.race(
                future,
                seconds: connectTimeoutSeconds,
                on: group.next(),
                error: { DatabaseError.connectionFailed("PostgreSQL connect timed out after \(connectTimeoutSeconds)s") },
                dispose: { conn in _ = conn.close() as EventLoopFuture<Void> }
            )
            conn = try await raced.get()

            let pidResult = try await conn.query("SELECT pg_backend_pid()", []).get()
            backendPID = pidResult.rows.first?.first.flatMap { try? $0.decode(Int.self) }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    static func makeTLS(_ sslOption: ConnectionSSLOption?, tls: ConnectionTLSConfig? = nil) throws -> PostgresConnection.Configuration.TLS {
        switch sslOption {
        case nil, .disable:
            return .disable
        case .prefer:
            // prefer：尽量加密，握手失败则回退明文（postgres-nio 内部处理回退）。
            let ctx = try NIOSSLContext(configuration: sslOption!.makeTLSConfiguration(tls: tls))
            return .prefer(ctx)
        case .require, .verifyCA, .verifyFull:
            // require/verify-ca/verify-full：强制加密，证书校验强度由 makeTLSConfiguration 决定。
            // postgres-nio 的 TLS 枚举没有 verifyFull case，校验差异通过 TLSConfiguration 表达。
            let ctx = try NIOSSLContext(configuration: sslOption!.makeTLSConfiguration(tls: tls))
            return .require(ctx)
        }
    }

    /// 主连接被长查询占住时，用第二条连接发 `pg_cancel_backend` 中止它，主连接保持可用。
    public func cancel() async {
        guard let backendPID, !conn.isClosed else { return }
        let context = cancelContext
        do {
            let config = PostgresConnection.Configuration(
                host: context.host,
                port: context.port,
                username: context.username,
                password: context.password ?? "",
                database: context.database,
                tls: try Self.makeTLS(context.sslOption, tls: context.tlsConfig)
            )
            let cancelConnection = try await PostgresConnection.connect(
                on: group.next(),
                configuration: config,
                id: 2,
                logger: logger
            ).get()
            _ = try await cancelConnection.query("SELECT pg_cancel_backend(\(backendPID))", []).get()
            try await cancelConnection.close()
        } catch {
            // 尽力而为：cancel 连接失败时不打断主连接，用户可重试或直接断开。
        }
    }

    static func mapCancellation(_ error: any Error) -> any Error {
        if let pgError = error as? PSQLError,
           pgError.code == .queryCancelled || pgError.serverInfo?[.sqlState] == "57014" {
            return DatabaseError.cancelled
        }
        return error
    }

    public func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        try ensureOpen()
        do {
            let result = try await conn.query(sql, toPostgresData(params ?? [])).get()
            return result.metadata.rows ?? result.rows.count
        } catch {
            throw Self.mapCancellation(error)
        }
    }

    public func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        try ensureOpen()
        do {
            let rowSequence = try await conn.query(
                PostgresQuery(unsafeSQL: sql, binds: toPostgresBindings(params ?? [])),
                logger: Logger(label: "com.lumi.postgres.query")
            )

            // 列名直接取自 RowDescription：SELECT 即使零行也会下发列元数据，
            // 无需临时表探针（旧探针在 autocommit 下临时表提前消失，导致空结果查询报错）。
            let columns = rowSequence.columns.map(\.name)
            var resultRows: [[DatabaseValue]] = []
            for try await row in rowSequence {
                var values: [DatabaseValue] = []
                for cell in row {
                    values.append(Self.convertCell(cell))
                }
                resultRows.append(values)
            }

            return QueryResult(columns: columns, rows: resultRows, rowsAffected: resultRows.count)
        } catch {
            throw Self.mapCancellation(error)
        }
    }

    public func beginTransaction() async throws -> any DatabaseTransaction {
        try ensureOpen()
        let query = PostgresQuery(unsafeSQL: "BEGIN")
        _ = try await conn.query(query, logger: Logger(label: "com.lumi.postgres.transaction")).get()
        return PGTransaction(connection: self)
    }

    public func close() async {
        try? await conn.close()
        try? await group.shutdownGracefully()
    }

    public func isAlive() async -> Bool {
        !conn.isClosed
    }

    /// 连接已关闭时立即抛错：PostgresNIO 的异步 row sequence 在「请求时连接已关闭」
    /// 的情况下不会完成也不会抛错，会永久挂起，必须先于 conn.query 拦截。
    private func ensureOpen() throws {
        guard !conn.isClosed else {
            throw DatabaseError.connectionFailed("PostgreSQL connection is closed")
        }
    }

    /// 按线上类型分派而不是字符串优先：String 解码对 int4 等类型同样成功，
    /// 试探式转换会把所有数字吞成文本。
    static func convertCell(_ cell: PostgresCell) -> DatabaseValue {
        switch cell.dataType {
        case .int2, .int4, .int8:
            if let i = try? cell.decode(Int.self) { return .integer(i) }
        case .float4, .float8:
            if let d = try? cell.decode(Double.self) { return .double(d) }
        case .numeric:
            if let d = try? cell.decode(Decimal.self) {
                return .double((d as NSDecimalNumber).doubleValue)
            }
        case .bool:
            if let b = try? cell.decode(Bool.self) { return .bool(b) }
        case .bytea:
            if var bytes = cell.bytes, let readBytes = bytes.readBytes(length: bytes.readableBytes) {
                return .data(Data(readBytes))
            }
        case .date:
            if let text = asciiText(cell) { return .string(text) }
            if var buf = cell.bytes, buf.readableBytes == 4, let days = buf.readInteger(as: Int32.self) {
                let (y, m, d) = civilDate(daysSince1970: Int(days) + 10957)
                return .string(String(format: "%04d-%02d-%02d", y, m, d))
            }
        case .timestamp, .timestamptz:
            if let text = asciiText(cell) { return .string(text) }
            if var buf = cell.bytes, buf.readableBytes == 8, let micros = buf.readInteger(as: Int64.self) {
                return .string(timestampText(micros: micros, withZone: cell.dataType == .timestamptz))
            }
        case .time, .timetz:
            if let text = asciiText(cell) { return .string(text) }
            if var buf = cell.bytes, buf.readableBytes == (cell.dataType == .timetz ? 12 : 8),
               let micros = buf.readInteger(as: Int64.self) {
                var zone: Int32? = nil
                if cell.dataType == .timetz { zone = buf.readInteger(as: Int32.self) }
                if cell.dataType == .time || zone != nil {
                    return .string(timeText(micros: micros, zone: zone))
                }
            }
        case .uuid:
            if let text = asciiText(cell) { return .string(text) }
            if let u = try? cell.decode(UUID.self) { return .string(u.uuidString.lowercased()) }
        default:
            if Self.arrayOIDs.contains(cell.dataType.rawValue), let text = arrayText(cell) {
                return .string(text)
            }
        }
        // String 兜底只接受纯文本：二进制载荷（如未知类型的定长字节）经 lossy UTF-8
        // 会混入 NUL/控制字符，直接展示即乱码，宁可落回 BLOB。
        if let s = try? cell.decode(String.self), isPlainText(s) { return .string(s) }
        if let i = try? cell.decode(Int.self) { return .integer(i) }
        if let d = try? cell.decode(Double.self) { return .double(d) }
        if let b = try? cell.decode(Bool.self) { return .bool(b) }
        if var bytes = cell.bytes, let readBytes = bytes.readBytes(length: bytes.readableBytes) {
            return .data(Data(readBytes))
        }
        return .null
    }

    // MARK: - 二进制解码（日期/时间/数组）

    /// 文本协议直通：纯可打印 ASCII 原样返回（enum 标签、text 格式结果等）。
    static func asciiText(_ cell: PostgresCell) -> String? {
        guard var buf = cell.bytes, buf.readableBytes > 0,
              let bytes = buf.readBytes(length: buf.readableBytes),
              bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// 拒绝含 NUL/控制字符的「字符串」（保留制表/换行/回车）。
    static func isPlainText(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.value >= 32 || $0.value == 9 || $0.value == 10 || $0.value == 13 }
    }

    /// 自 1970-01-01 起的天数 → 公历年月日（纯整数民用历算法，无 Foundation 格式化开销）。
    static func civilDate(daysSince1970: Int) -> (year: Int, month: Int, day: Int) {
        let z = daysSince1970 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 向下取整除法（Swift 的 `/` 向零取整，1970 前的负秒数会错一天）。
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// 微秒小数后缀：去掉尾零（PG 文本风格 `.5` 而非 `.500000`）；0 返回空串。
    static func fractionSuffix(_ micro: Int) -> String {
        guard micro > 0 else { return "" }
        var s = String(format: "%06d", micro)
        while s.hasSuffix("0") { s.removeLast() }
        return "." + s
    }

    /// timestamp/timestamptz 二进制：自 2000-01-01 UTC 起的 Int64 微秒。
    /// timestamptz 统一按 UTC 展示并附 `+00`，保证编辑往返不漂移。
    static func timestampText(micros: Int64, withZone: Bool) -> String {
        var seconds = micros / 1_000_000
        var micro = Int(micros % 1_000_000)
        if micro < 0 { micro += 1_000_000; seconds -= 1 }
        let total = seconds + 946_684_800
        let days = floorDiv(total, 86400)
        let sod = total - days * 86400
        let (y, m, d) = civilDate(daysSince1970: Int(days))
        var text = String(format: "%04d-%02d-%02d %02d:%02d:%02d", y, m, d, sod / 3600, (sod % 3600) / 60, sod % 60)
        text += fractionSuffix(micro)
        if withZone { text += "+00" }
        return text
    }

    /// time/timetz 二进制：自午夜起的 Int64 微秒；timetz 追加 Int32 时区（UTC 以西秒数）。
    static func timeText(micros: Int64, zone: Int32?) -> String {
        let seconds = micros / 1_000_000
        let micro = Int(micros % 1_000_000)
        var text = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        text += fractionSuffix(micro)
        if let zone {
            // 显示翻转为东正西负（PG 存储为西正）。
            let east = -Int(zone)
            let sign = east < 0 ? "-" : "+"
            let magnitude = abs(east)
            text += String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        }
        return text
    }

    /// 按元素二进制格式渲染的常见数组 OID；其余数组落回 BLOB 展示。
    private static let arrayOIDs: Set<UInt32> = Set(([
        .boolArray, .byteaArray, .charArray, .nameArray, .int2Array, .int4Array,
        .textArray, .bpcharArray, .varcharArray, .int8Array, .float4Array, .float8Array,
        .timestampArray, .dateArray, .timeArray, .timestamptzArray, .timetzArray,
        .numericArray, .uuidArray, .jsonArray, .jsonbArray,
    ] as [PostgresDataType]).map(\.rawValue))

    /// PG 二进制数组 → 文本字面量（`{1,2,3}`，多维嵌套，NULL 大写）。
    /// 头部：Int32 维数、Int32 含空标志、UInt32 元素 OID，每维 (Int32 长度, Int32 下界)。
    static func arrayText(_ cell: PostgresCell) -> String? {
        guard var buf = cell.bytes, buf.readableBytes >= 12,
              let ndim = buf.readInteger(as: Int32.self),
              let _ = buf.readInteger(as: Int32.self),
              let elementOID = buf.readInteger(as: UInt32.self),
              ndim >= 0, ndim <= 6 else { return nil }
        if ndim == 0 { return "{}" }
        var dims: [Int] = []
        for _ in 0..<ndim {
            guard let size = buf.readInteger(as: Int32.self),
                  let _ = buf.readInteger(as: Int32.self), size >= 0 else { return nil }
            dims.append(Int(size))
        }
        guard let text = renderArrayLevel(buf: &buf, dims: dims[...], elementOID: elementOID),
              buf.readableBytes == 0 else { return nil }
        return text
    }

    private static func renderArrayLevel(buf: inout ByteBuffer, dims: ArraySlice<Int>, elementOID: UInt32) -> String? {
        guard let count = dims.first else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(count)
        for _ in 0..<count {
            if dims.count == 1 {
                guard let len = buf.readInteger(as: Int32.self) else { return nil }
                if len == -1 {
                    parts.append("NULL")
                    continue
                }
                guard len >= 0, let payload = buf.readBytes(length: Int(len)),
                      let text = arrayElementText(Data(payload), oid: elementOID) else { return nil }
                parts.append(text)
            } else {
                guard let sub = renderArrayLevel(buf: &buf, dims: dims.dropFirst(), elementOID: elementOID) else { return nil }
                parts.append(sub)
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// 单个数组元素按元素 OID 的二进制格式渲染；不支持的类型返回 nil（整个数组落回 BLOB）。
    private static func arrayElementText(_ data: Data, oid: UInt32) -> String? {
        var buf = ByteBuffer()
        buf.writeBytes(data)
        switch oid {
        case 16: // bool
            guard let b = buf.readInteger(as: UInt8.self) else { return nil }
            return b == 0 ? "f" : "t"
        case 21:
            guard let v = buf.readInteger(as: Int16.self) else { return nil }
            return String(v)
        case 23:
            guard let v = buf.readInteger(as: Int32.self) else { return nil }
            return String(v)
        case 20:
            guard let v = buf.readInteger(as: Int64.self) else { return nil }
            return String(v)
        case 700:
            guard let v = buf.readInteger(as: UInt32.self) else { return nil }
            return String(Float(bitPattern: v))
        case 701:
            guard let v = buf.readInteger(as: UInt64.self) else { return nil }
            return String(Double(bitPattern: v))
        case 1700:
            return numericText(buf: &buf)
        case 1082: // date
            guard let days = buf.readInteger(as: Int32.self) else { return nil }
            let (y, m, d) = civilDate(daysSince1970: Int(days) + 10957)
            return String(format: "%04d-%02d-%02d", y, m, d)
        case 1114, 1184: // timestamp / timestamptz
            guard let micros = buf.readInteger(as: Int64.self) else { return nil }
            return timestampText(micros: micros, withZone: oid == 1184)
        case 1083, 1266: // time / timetz
            guard let micros = buf.readInteger(as: Int64.self) else { return nil }
            var zone: Int32? = nil
            if oid == 1266 { zone = buf.readInteger(as: Int32.self) }
            guard oid == 1083 || zone != nil else { return nil }
            return timeText(micros: micros, zone: zone)
        case 2950: // uuid
            guard data.count == 16 else { return nil }
            let u = UUID(uuid: (data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
                                data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15]))
            return quoteArrayElement(u.uuidString.lowercased())
        case 17: // bytea → hex 字面量
            return quoteArrayElement("\\x" + data.map { String(format: "%02x", $0) }.joined())
        case 18, 19, 25, 1042, 1043, 114: // char/name/text/bpchar/varchar/json
            guard let s = String(data: data, encoding: .utf8) else { return nil }
            return quoteArrayElement(s)
        case 3802: // jsonb：首字节为版本号
            guard data.count >= 1, data[0] == 1,
                  let s = String(data: data.dropFirst(), encoding: .utf8) else { return nil }
            return quoteArrayElement(s)
        default:
            return nil
        }
    }

    /// 数组文本元素按 PG 字面量规则加引号：空串、NULL 或含 `{},"\` 空白须转义。
    static func quoteArrayElement(_ s: String) -> String {
        let needsQuote = s.isEmpty || s.uppercased() == "NULL"
            || s.contains(where: { $0 == "{" || $0 == "}" || $0 == "," || $0 == "\"" || $0 == "\\" || $0.isWhitespace })
        guard needsQuote else { return s }
        var escaped = ""
        for ch in s {
            if ch == "\"" || ch == "\\" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"" + escaped + "\""
    }

    /// numeric 二进制：Int16 组数/权重、UInt16 符号、Int16 小数位，随后每组 UInt16（万进制）。
    static func numericText(buf: inout ByteBuffer) -> String? {
        guard let ndigits = buf.readInteger(as: Int16.self),
              let weight = buf.readInteger(as: Int16.self),
              let sign = buf.readInteger(as: UInt16.self),
              let dscale = buf.readInteger(as: Int16.self),
              ndigits >= 0, dscale >= 0 else { return nil }
        if sign == 0xC000 { return "NaN" }
        if sign == 0xD000 { return "Infinity" }
        if sign == 0xF000 { return "-Infinity" }
        guard sign == 0x0000 || sign == 0x4000 else { return nil }
        var digits: [Int] = []
        digits.reserveCapacity(Int(ndigits))
        for _ in 0..<ndigits {
            guard let d = buf.readInteger(as: UInt16.self), d < 10000 else { return nil }
            digits.append(Int(d))
        }
        var intPart = "0"
        if weight >= 0 {
            var s = ""
            for i in 0...Int(weight) {
                let g = i < digits.count ? digits[i] : 0
                s += i == 0 ? String(g) : String(format: "%04d", g)
            }
            intPart = s
        }
        var text = intPart
        if dscale > 0 {
            var frac = ""
            for j in 1...((Int(dscale) + 3) / 4) {
                let i = Int(weight) + j
                let g = (i >= 0 && i < digits.count) ? digits[i] : 0
                frac += String(format: "%04d", g)
            }
            text += "." + frac.prefix(Int(dscale))
        }
        let negative = sign == 0x4000 && digits.contains(where: { $0 != 0 })
        return (negative ? "-" : "") + text
    }

    private func toPostgresData(_ params: [DatabaseValue]) -> [PostgresData] {
        params.map { value in
            switch value {
            case .integer(let int): return PostgresData(int: int)
            case .double(let double): return PostgresData(double: double)
            case .string(let string): return PostgresData(string: string)
            case .bool(let bool): return PostgresData(bool: bool)
            case .data(let data): return PostgresData(bytes: data)
            case .null: return .null
            }
        }
    }

    private func toPostgresBindings(_ params: [DatabaseValue]) -> PostgresBindings {
        var bindings = PostgresBindings(capacity: params.count)
        toPostgresData(params).forEach { bindings.append($0) }
        return bindings
    }
}

public final actor PGTransaction: DatabaseTransaction {
    private let connection: PGConnection
    private var completed = false

    init(connection: PGConnection) {
        self.connection = connection
    }

    public func commit() async throws {
        guard !completed else { throw DatabaseError.transactionFailed("Transaction already completed") }
        _ = try await connection.execute("COMMIT", params: nil)
        completed = true
    }

    public func rollback() async throws {
        guard !completed else { throw DatabaseError.transactionFailed("Transaction already completed") }
        _ = try await connection.execute("ROLLBACK", params: nil)
        completed = true
    }

    public func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        guard !completed else { throw DatabaseError.transactionFailed("Transaction already completed") }
        return try await connection.execute(sql, params: params)
    }
}
#else
public final class PostgreSQLDriver: DatabaseDriver, Sendable {
    public var type: DatabaseType { .postgresql }

    public init() {}

    public func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        throw DatabaseError.notImplemented
    }
}
#endif
