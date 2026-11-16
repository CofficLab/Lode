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
    }

    public init(host: String, port: Int, username: String, password: String?, database: String, sslOption: ConnectionSSLOption? = nil, connectTimeoutSeconds: Int = 10) async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        cancelContext = CancelContext(
            host: host, port: port, username: username,
            password: password, database: database, sslOption: sslOption
        )

        do {
            var config = PostgresConnection.Configuration(
                host: host,
                port: port,
                username: username,
                password: password ?? "",
                database: database,
                tls: try Self.makeTLS(sslOption)
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

    static func makeTLS(_ sslOption: ConnectionSSLOption?) throws -> PostgresConnection.Configuration.TLS {
        switch sslOption {
        case nil, .disable:
            return .disable
        case .prefer:
            // prefer：尽量加密，握手失败则回退明文（postgres-nio 内部处理回退）。
            let ctx = try NIOSSLContext(configuration: sslOption!.makeTLSConfiguration())
            return .prefer(ctx)
        case .require, .verifyCA, .verifyFull:
            // require/verify-ca/verify-full：强制加密，证书校验强度由 makeTLSConfiguration 决定。
            // postgres-nio 的 TLS 枚举没有 verifyFull case，校验差异通过 TLSConfiguration 表达。
            let ctx = try NIOSSLContext(configuration: sslOption!.makeTLSConfiguration())
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
                tls: try Self.makeTLS(context.sslOption)
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
        default:
            break
        }
        if let s = try? cell.decode(String.self) { return .string(s) }
        if let i = try? cell.decode(Int.self) { return .integer(i) }
        if let d = try? cell.decode(Double.self) { return .double(d) }
        if let b = try? cell.decode(Bool.self) { return .bool(b) }
        if var bytes = cell.bytes, let readBytes = bytes.readBytes(length: bytes.readableBytes) {
            return .data(Data(readBytes))
        }
        return .null
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
