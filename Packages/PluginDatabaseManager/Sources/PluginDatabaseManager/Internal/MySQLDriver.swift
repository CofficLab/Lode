import Foundation

#if canImport(MySQLNIO)
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

public final class MySQLDriver: DatabaseDriver, Sendable {
    public var type: DatabaseType { .mysql }

    public init() {}

    public func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        guard let host = config.host, !host.isEmpty else {
            throw DatabaseError.invalidConfiguration("MySQL 需要有效的主机地址")
        }
        let port = try config.validatedNetworkPort(serviceName: "MySQL")
        guard !config.database.isEmpty else {
            throw DatabaseError.invalidConfiguration("MySQL 需要指定数据库名")
        }
        guard let user = config.username, !user.isEmpty else {
            throw DatabaseError.invalidConfiguration("MySQL 需要用户名")
        }

        return try await MySQLConnection(
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

public actor MySQLConnection: DatabaseConnection {
    private let group: EventLoopGroup
    private var conn: MySQLNIO.MySQLConnection?
    private let cancelContext: CancelContext
    private var connectionID: Int?

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
            let socketAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
            let tlsConfiguration: TLSConfiguration? = {
                guard let ssl = sslOption, ssl.enablesTLS else { return nil }
                return ssl.makeTLSConfiguration(tls: tlsConfig)
            }()
            let future = MySQLNIO.MySQLConnection.connect(
                to: socketAddress,
                username: username,
                database: database,
                password: password,
                tlsConfiguration: tlsConfiguration,
                serverHostname: sslOption?.enablesTLS == true ? host : nil,
                on: group.next()
            )
            let raced = ConnectTimeout.race(
                future,
                seconds: connectTimeoutSeconds,
                on: group.next(),
                error: { DatabaseError.connectionFailed("MySQL connect timed out after \(connectTimeoutSeconds)s") },
                dispose: { conn in _ = conn.close() }
            )
            conn = try await raced.get()
            let idRows = try await conn?.query("SELECT CONNECTION_ID() AS id").get()
            connectionID = idRows?.first?.column("id")?.int
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// 主连接被长查询占住时，用第二条连接发 `KILL QUERY` 中止它，主连接保持可用。
    public func cancel() async {
        guard let connectionID, let conn, !conn.isClosed else { return }
        let context = cancelContext
        do {
            let socketAddress = try SocketAddress.makeAddressResolvingHost(context.host, port: context.port)
            let tlsConfiguration: TLSConfiguration? = {
                guard let ssl = context.sslOption, ssl.enablesTLS else { return nil }
                return ssl.makeTLSConfiguration(tls: context.tlsConfig)
            }()
            let killConnection = try await MySQLNIO.MySQLConnection.connect(
                to: socketAddress,
                username: context.username,
                database: context.database,
                password: context.password,
                tlsConfiguration: tlsConfiguration,
                serverHostname: context.sslOption?.enablesTLS == true ? context.host : nil,
                on: group.next()
            ).get()
            _ = try await killConnection.simpleQuery("KILL QUERY \(connectionID)").get()
            try await killConnection.close().get()
        } catch {
            // 尽力而为：kill 连接失败时不打断主连接，用户可重试或直接断开。
        }
    }

    static func mapCancellation(_ error: any Error) -> any Error {
        if let mysqlError = error as? MySQLError,
           case .server(let packet) = mysqlError,
           packet.errorCode == .QUERY_INTERRUPTED {
            return DatabaseError.cancelled
        }
        return error
    }

    public func execute(_ sql: String, params: [DatabaseValue]?) async throws -> Int {
        guard let conn else { throw DatabaseError.connectionFailed("Not connected") }
        let metadataStore = MySQLQueryMetadataStore()
        do {
            _ = try await conn.query(
                sql,
                toMySQLData(params ?? []),
                onMetadata: { metadata in
                    metadataStore.setAffectedRows(Int(metadata.affectedRows))
                }
            ).get()
        } catch {
            // CREATE TRIGGER/PROCEDURE/FUNCTION 等不支持预处理协议（ER_UNSUPPORTED_PS）；
            // 无绑定参数时改走文本协议。有参数时不能安全内插，保留原错误。
            if Self.isUnsupportedPreparedStatement(error), (params ?? []).isEmpty {
                do {
                    _ = try await conn.simpleQuery(sql).get()
                } catch {
                    throw Self.mapCancellation(error)
                }
                return 0
            }
            throw Self.mapCancellation(error)
        }
        return metadataStore.affectedRows
    }

    public func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        guard let conn else { throw DatabaseError.connectionFailed("Not connected") }
        do {
            let rows = try await conn.query(sql, toMySQLData(params ?? [])).get()
            return try await Self.queryResult(from: rows, sql: sql, params: params, connection: self)
        } catch {
            if Self.isUnsupportedPreparedStatement(error), (params ?? []).isEmpty {
                do {
                    let rows = try await conn.simpleQuery(sql).get()
                    return try await Self.queryResult(from: rows, sql: sql, params: params, connection: self)
                } catch {
                    throw Self.mapCancellation(error)
                }
            }
            throw Self.mapCancellation(error)
        }
    }

    private static func isUnsupportedPreparedStatement(_ error: any Error) -> Bool {
        guard let mysqlError = error as? MySQLError,
              case .server(let packet) = mysqlError else { return false }
        return packet.errorCode == .UNSUPPORTED_PS
    }

    private static func queryResult(
        from rows: [MySQLRow],
        sql: String,
        params: [DatabaseValue]?,
        connection: MySQLConnection
    ) async throws -> QueryResult {
        var resultRows: [[DatabaseValue]] = []
        var columns: [String] = []
        if let first = rows.first {
            columns = first.columnDefinitions.map(\.name)
        }

        for row in rows {
            var values: [DatabaseValue] = []
            for colDef in row.columnDefinitions {
                if let data = row.column(colDef.name) {
                    values.append(convertValue(data, columnType: colDef.columnType))
                } else {
                    values.append(.null)
                }
            }
            resultRows.append(values)
        }

        if columns.isEmpty, let probeSQL = normalizedSelectForColumnProbe(sql) {
            columns = try await connection.queryColumnNames(for: probeSQL, params: params ?? [])
        }

        return QueryResult(columns: columns, rows: resultRows, rowsAffected: 0)
    }

    public func beginTransaction() async throws -> any DatabaseTransaction {
        guard let conn else { throw DatabaseError.connectionFailed("Not connected") }
        _ = try await conn.simpleQuery("BEGIN").get()
        return MySQLTransaction(connection: self)
    }

    public func close() async {
        guard let conn else { return }
        try? await conn.close().get()
        self.conn = nil
        try? await group.shutdownGracefully()
    }

    public func isAlive() async -> Bool {
        guard let conn else { return false }
        return !conn.isClosed
    }

    /// 按列的线上类型分派而不是字符串优先：文本协议下任何值都能读成字符串，
    /// 试探式转换会把数字/布尔全部吞成文本。
    static func convertValue(_ data: MySQLData, columnType: MySQLProtocol.DataType) -> DatabaseValue {
        switch columnType {
        case .null:
            return .null
        case .tiny, .short, .long, .longlong, .int24, .year:
            if let i = data.int { return .integer(i) }
        case .float, .double, .decimal, .newdecimal:
            if let d = data.double { return .double(d) }
        case .bit, .tinyBlob, .mediumBlob, .longBlob, .blob, .geometry:
            if var buffer = data.buffer, let bytes = buffer.readBytes(length: buffer.readableBytes) {
                return .data(Data(bytes))
            }
        case .date, .datetime, .timestamp, .newdate, .datetime2, .timestamp2:
            if let text = Self.temporalText(data, isTime: false) { return .string(text) }
        case .time, .time2:
            if let text = Self.temporalText(data, isTime: true) { return .string(text) }
        default:
            break
        }
        if let s = data.string { return .string(s) }
        if let i = data.int { return .integer(i) }
        if let d = data.double { return .double(d) }
        if let b = data.bool { return .bool(b) }
        if var buffer = data.buffer, let bytes = buffer.readBytes(length: buffer.readableBytes) {
            return .data(Data(bytes))
        }
        return .null
    }

    /// 日期/时间列的线上载荷 → 规范文本。
    ///
    /// 二进制协议下 MySQLNIO 已剥掉长度前缀：DATE/DATETIME/TIMESTAMP 为
    /// 4（年月日）/7（+时分秒）/11（+微秒）字节；TIME 为 8（符号+天数+时分秒）/
    /// 12（+微秒）字节。文本协议下载荷是可打印 ASCII，直接还原。
    static func temporalText(_ data: MySQLData, isTime: Bool) -> String? {
        guard var buffer = data.buffer, let bytes = buffer.readBytes(length: buffer.readableBytes) else { return nil }
        if bytes.isEmpty { return isTime ? "00:00:00" : "0000-00-00 00:00:00" }
        if let text = String(data: Data(bytes), encoding: .utf8),
           text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) {
            return text
        }
        func le32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        if isTime {
            guard bytes.count == 8 || bytes.count == 12 else { return nil }
            let negative = bytes[0] != 0
            let hours = le32(1) * 24 + Int(bytes[5])
            let base = String(format: "%@%02d:%02d:%02d", negative ? "-" : "", hours, Int(bytes[6]), Int(bytes[7]))
            let micro = bytes.count == 12 ? le32(8) : 0
            return micro == 0 ? base : base + String(format: ".%06d", micro)
        }
        guard bytes.count == 4 || bytes.count == 7 || bytes.count == 11 else { return nil }
        let date = String(format: "%04d-%02d-%02d", Int(bytes[0]) | Int(bytes[1]) << 8, Int(bytes[2]), Int(bytes[3]))
        if bytes.count == 4 { return date }
        let base = date + String(format: " %02d:%02d:%02d", Int(bytes[4]), Int(bytes[5]), Int(bytes[6]))
        let micro = bytes.count == 11 ? le32(7) : 0
        return micro == 0 ? base : base + String(format: ".%06d", micro)
    }

    private func toMySQLData(_ params: [DatabaseValue]) -> [MySQLData] {
        params.map { value in
            switch value {
            case .integer(let int): return MySQLData(int: int)
            case .double(let double): return MySQLData(double: double)
            case .string(let string): return MySQLData(string: string)
            case .bool(let bool): return MySQLData(bool: bool)
            case .data(let data):
                return MySQLData(type: .blob, buffer: ByteBuffer(bytes: data))
            case .null:
                return .null
            }
        }
    }

    static func normalizedSelectForColumnProbe(_ sql: String) -> String? {
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !trimmed.contains(";") else { return nil }
        guard trimmed.range(of: #"^\s*select\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return trimmed
    }

    /// 零行结果时探测列名。
    ///
    /// MySQL 协议在零行时不会把列定义交给客户端，驱动拿不到列名。
    /// 这里用会话临时表复制查询结构，再读它的列定义。
    ///
    /// 注意：会话临时表**不**出现在 `INFORMATION_SCHEMA.COLUMNS` 中
    /// （该 catalog 只列永久表），所以必须用 `SHOW COLUMNS` 读取。
    private func queryColumnNames(for sql: String, params: [DatabaseValue]) async throws -> [String] {
        guard let conn else { throw DatabaseError.connectionFailed("Not connected") }

        let tableName = "databasekit_column_probe_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let tableIdentifier = quoteIdentifier(tableName)
        let createSQL = "CREATE TEMPORARY TABLE \(tableIdentifier) AS \(sql) LIMIT 0"

        do {
            _ = try await conn.query(createSQL, toMySQLData(params)).get()
            let rows = try await conn.query("SHOW COLUMNS FROM \(tableIdentifier)").get()
            try await dropTemporaryTable(tableIdentifier)
            return rows.compactMap { row in
                row.column("Field")?.string ?? row.column("field")?.string
            }
        } catch {
            try? await dropTemporaryTable(tableIdentifier)
            throw error
        }
    }

    private func dropTemporaryTable(_ tableIdentifier: String) async throws {
        guard let conn else { return }
        _ = try await conn.query("DROP TEMPORARY TABLE IF EXISTS \(tableIdentifier)").get()
    }

    private func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }
}

public final actor MySQLTransaction: DatabaseTransaction {
    private let connection: MySQLConnection
    private var completed = false

    init(connection: MySQLConnection) {
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

private final class MySQLQueryMetadataStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _affectedRows = 0

    var affectedRows: Int {
        lock.lock()
        defer { lock.unlock() }
        return _affectedRows
    }

    func setAffectedRows(_ affectedRows: Int) {
        lock.lock()
        _affectedRows = affectedRows
        lock.unlock()
    }
}
#else
public final class MySQLDriver: DatabaseDriver, Sendable {
    public var type: DatabaseType { .mysql }

    public init() {}

    public func connect(config: DatabaseConfig) async throws -> any DatabaseConnection {
        throw DatabaseError.notImplemented
    }
}
#endif
