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
            sslOption: config.sslOption
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

    public init(host: String, port: Int, username: String, password: String?, database: String, sslOption: ConnectionSSLOption? = nil) async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        cancelContext = CancelContext(
            host: host, port: port, username: username,
            password: password, database: database, sslOption: sslOption
        )

        let config = PostgresConnection.Configuration(
            host: host,
            port: port,
            username: username,
            password: password ?? "",
            database: database,
            tls: try Self.makeTLS(sslOption)
        )

        conn = try await PostgresConnection.connect(
            on: group.next(),
            configuration: config,
            id: 1,
            logger: logger
        ).get()

        let pidResult = try await conn.query("SELECT pg_backend_pid()", []).get()
        backendPID = pidResult.rows.first?.first.flatMap { try? $0.decode(Int.self) }
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
        do {
            let result = try await conn.query(sql, toPostgresData(params ?? [])).get()
            return result.metadata.rows ?? result.rows.count
        } catch {
            throw Self.mapCancellation(error)
        }
    }

    public func query(_ sql: String, params: [DatabaseValue]?) async throws -> QueryResult {
        do {
            let rowSequence = try await conn.query(
                PostgresQuery(unsafeSQL: sql, binds: toPostgresBindings(params ?? [])),
                logger: Logger(label: "com.lumi.postgres.query")
            )

            var columns: [String] = []
            var resultRows: [[DatabaseValue]] = []

            for try await row in rowSequence {
                var values: [DatabaseValue] = []
                for cell in row {
                    if resultRows.isEmpty {
                        columns.append(cell.columnName)
                    }
                    values.append(Self.convertCell(cell))
                }
                resultRows.append(values)
            }

            if columns.isEmpty, let probeSQL = Self.normalizedSelectForColumnProbe(sql) {
                columns = try await queryColumnNames(for: probeSQL, params: params ?? [])
            }

            return QueryResult(columns: columns, rows: resultRows, rowsAffected: resultRows.count)
        } catch {
            throw Self.mapCancellation(error)
        }
    }

    public func beginTransaction() async throws -> any DatabaseTransaction {
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

    private func queryColumnNames(for sql: String, params: [DatabaseValue]) async throws -> [String] {
        let tableName = "databasekit_column_probe_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let tableIdentifier = quoteIdentifier(tableName)
        let createSQL = "CREATE TEMPORARY TABLE \(tableIdentifier) ON COMMIT DROP AS \(sql) WITH NO DATA"
        let createQuery = PostgresQuery(unsafeSQL: createSQL, binds: toPostgresBindings(params))

        do {
            _ = try await conn.query(createQuery, logger: Logger(label: "com.lumi.postgres.columns")).get()
            let result = try await conn.query(
                """
                SELECT attname
                FROM pg_attribute
                WHERE attrelid = $1::regclass
                    AND attnum > 0
                    AND NOT attisdropped
                ORDER BY attnum
                """,
                [PostgresData(string: tableName)]
            ).get()
            try await dropTemporaryTable(tableIdentifier)
            return result.rows.compactMap { row in
                row.first.flatMap { try? $0.decode(String.self) }
            }
        } catch {
            try? await dropTemporaryTable(tableIdentifier)
            throw error
        }
    }

    private func dropTemporaryTable(_ tableIdentifier: String) async throws {
        let query = PostgresQuery(unsafeSQL: "DROP TABLE IF EXISTS \(tableIdentifier)")
        _ = try await conn.query(query, logger: Logger(label: "com.lumi.postgres.columns")).get()
    }

    private func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
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
