@testable import DatabaseManagerPlugin
import Foundation
import Testing

#if canImport(MySQLNIO)
import MySQLNIO
import NIOCore
#endif
#if canImport(Network)
import Network
#endif

/// 错误分类器的映射不变量：结构化错误码、SQLSTATE、网络错误与文本兜底。
struct DatabaseErrorClassifierTests {
    // MARK: - MySQL 错误码（真实 ERR_Packet 解码构造）

    #if canImport(MySQLNIO)
    private func mysqlError(code: UInt16, message: String = "server detail") -> MySQLError {
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        buffer.writeInteger(UInt8(0xFF))
        buffer.writeInteger(code, endianness: .little)
        buffer.writeString("#")
        buffer.writeString("HY000")
        buffer.writeString(message)
        var packet = MySQLPacket(payload: buffer)
        let err = try! MySQLProtocol.ERR_Packet.decode(from: &packet, capabilities: [.CLIENT_PROTOCOL_41])
        return .server(err)
    }

    @Test func mysqlAccessDeniedIsAuthentication() {
        let classified = DatabaseErrorClassifier.classify(mysqlError(code: 1045, message: "Access denied for user 'root'@'localhost'"))
        #expect(classified.category == .authenticationFailed)
        #expect(classified.recovery == .editConnection)
        #expect(classified.detail.contains("Access denied"))
    }

    @Test func mysqlBadDatabaseIsDatabaseNotFound() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 1049)).category == .databaseNotFound)
    }

    @Test func mysqlDBAccessDeniedIsPermission() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 1044)).category == .permissionDenied)
    }

    @Test func mysqlTableAccessDeniedIsPermission() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 1142)).category == .permissionDenied)
    }

    @Test func mysqlParseErrorIsSyntax() {
        let classified = DatabaseErrorClassifier.classify(mysqlError(code: 1064))
        #expect(classified.category == .syntaxError)
        #expect(classified.recovery == DatabaseErrorRecovery.none)
    }

    @Test func mysqlNoSuchTableIsSyntax() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 1146)).category == .syntaxError)
    }

    @Test func mysqlQueryInterruptedIsCancelled() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 1317)).category == .cancelled)
    }

    @Test func mysqlConnHostErrorIsNetworkUnreachable() {
        let classified = DatabaseErrorClassifier.classify(mysqlError(code: 2003))
        #expect(classified.category == .networkUnreachable)
        #expect(classified.recovery == .retry)
    }

    @Test func mysqlServerGoneIsConnectionLost() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 2006)).category == .connectionLost)
    }

    @Test func mysqlServerLostIsConnectionLost() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 2013)).category == .connectionLost)
    }

    @Test func mysqlLockWaitTimeoutIsTimeout() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 1205)).category == .timeout)
    }

    @Test func mysqlDuplicateEntryIsServerError() {
        #expect(DatabaseErrorClassifier.classify(mysqlError(code: 1062)).category == .serverError)
    }

    @Test func mysqlNonServerCases() {
        #expect(DatabaseErrorClassifier.classify(MySQLError.invalidSyntax("bad sql")).category == .syntaxError)
        #expect(DatabaseErrorClassifier.classify(MySQLError.closed).category == .connectionLost)
        #expect(DatabaseErrorClassifier.classify(MySQLError.duplicateEntry("dup")).category == .serverError)
        #expect(DatabaseErrorClassifier.classify(MySQLError.secureConnectionRequired).category == .authenticationFailed)
    }
    #endif

    // MARK: - PostgreSQL SQLSTATE

    @Test(arguments: [
        ("28P01", DatabaseErrorCategory.authenticationFailed),
        ("28000", .authenticationFailed),
        ("3D000", .databaseNotFound),
        ("42501", .permissionDenied),
        ("42601", .syntaxError),
        ("42703", .syntaxError),
        ("42P01", .syntaxError),
        ("57014", .cancelled),
        ("57P01", .connectionLost),
        ("57P02", .connectionLost),
        ("08006", .connectionLost),
        ("08003", .connectionLost),
        ("53300", .serverError),
        ("XX000", .serverError),
    ])
    func sqlStateMapping(sqlState: String, expected: DatabaseErrorCategory) {
        #expect(DatabaseErrorClassifier.category(ofSQLState: sqlState) == expected)
    }

    // MARK: - DatabaseError 与文本兜底（含 SQLite errmsg）

    @Test func databaseErrorCancelled() {
        #expect(DatabaseErrorClassifier.classify(DatabaseError.cancelled).category == .cancelled)
    }

    @Test func databaseErrorInvalidConfigurationIsUnknown() {
        #expect(DatabaseErrorClassifier.classify(DatabaseError.invalidConfiguration("bad port")).category == .unknown)
        #expect(DatabaseErrorClassifier.classify(DatabaseError.driverNotFound(.mysql)).category == .unknown)
    }

    @Test(arguments: [
        ("Access denied for user 'root'@'localhost' (using password: YES)", DatabaseErrorCategory.authenticationFailed),
        ("password authentication failed for user \"postgres\"", .authenticationFailed),
        ("Unknown database 'nope'", .databaseNotFound),
        ("database \"nope\" does not exist", .databaseNotFound),
        ("permission denied for table t", .permissionDenied),
        ("near \"SELEC\": syntax error", .syntaxError),
        ("no such table: missing", .syntaxError),
        ("no such column: x", .syntaxError),
        ("Table 'testdb.missing' doesn't exist", .syntaxError),
        ("connection timed out", .timeout),
        ("Connection refused", .networkUnreachable),
        ("unable to open database file", .networkUnreachable),
        ("Can't connect to MySQL server on '127.0.0.1'", .networkUnreachable),
        ("MySQL server has gone away", .connectionLost),
        ("Lost connection to MySQL server during query", .connectionLost),
        ("server closed the connection unexpectedly", .connectionLost),
        ("Not connected", .connectionLost),
        ("attempt to write a readonly database", .serverError),
        ("database is locked", .serverError),
        ("something entirely unexpected", .unknown),
    ])
    func textFallback(message: String, expected: DatabaseErrorCategory) {
        #expect(DatabaseErrorClassifier.categoryFromText(message) == expected)
        #expect(DatabaseErrorClassifier.classify(DatabaseError.queryFailed(message)).category == expected)
    }

    // MARK: - 网络错误

    #if canImport(Network)
    @Test func nwPosixMapping() {
        #expect(DatabaseErrorClassifier.classify(NWError.posix(.ECONNREFUSED)).category == .networkUnreachable)
        #expect(DatabaseErrorClassifier.classify(NWError.posix(.EHOSTUNREACH)).category == .networkUnreachable)
        #expect(DatabaseErrorClassifier.classify(NWError.posix(.ETIMEDOUT)).category == .timeout)
        #expect(DatabaseErrorClassifier.classify(NWError.posix(.ECONNRESET)).category == .connectionLost)
        #expect(DatabaseErrorClassifier.classify(NWError.posix(.EPIPE)).category == .connectionLost)
    }
    #endif

    // MARK: - NIO errno 错误

    #if canImport(NIOCore)
    @Test func nioErrnoMapping() {
        #expect(DatabaseErrorClassifier.category(ofErrno: ECONNREFUSED) == .networkUnreachable)
        #expect(DatabaseErrorClassifier.category(ofErrno: EHOSTUNREACH) == .networkUnreachable)
        #expect(DatabaseErrorClassifier.category(ofErrno: ETIMEDOUT) == .timeout)
        #expect(DatabaseErrorClassifier.category(ofErrno: ECONNRESET) == .connectionLost)
        #expect(DatabaseErrorClassifier.category(ofErrno: EPIPE) == .connectionLost)
        #expect(DatabaseErrorClassifier.category(ofErrno: EACCES) == .unknown)
    }
    #endif

    // MARK: - 包装错误与恢复动作

    private struct WrappedError: LocalizedError, CustomNSError {
        var errorDescription: String? { "wrapped failure" }
        var underlying: Error?
        var errorUserInfo: [String: Any] {
            underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:]
        }
    }

    #if canImport(MySQLNIO)
    @Test func unwrapsUnderlyingError() {
        let wrapped = WrappedError(underlying: mysqlError(code: 1045))
        #expect(DatabaseErrorClassifier.classify(wrapped).category == .authenticationFailed)
    }
    #endif

    @Test func unknownWrappedErrorFallsBackToText() {
        let wrapped = WrappedError(underlying: DatabaseError.notImplemented)
        #expect(DatabaseErrorClassifier.classify(wrapped).category == .unknown)
    }

    @Test func recoveryActionsPerCategory() {
        #expect(DatabaseErrorCategory.networkUnreachable.suggestedRecovery == .retry)
        #expect(DatabaseErrorCategory.timeout.suggestedRecovery == .retry)
        #expect(DatabaseErrorCategory.connectionLost.suggestedRecovery == .retry)
        #expect(DatabaseErrorCategory.authenticationFailed.suggestedRecovery == .editConnection)
        #expect(DatabaseErrorCategory.databaseNotFound.suggestedRecovery == .editConnection)
        #expect(DatabaseErrorCategory.permissionDenied.suggestedRecovery == .editConnection)
        #expect(DatabaseErrorCategory.syntaxError.suggestedRecovery == DatabaseErrorRecovery.none)
        #expect(DatabaseErrorCategory.cancelled.suggestedRecovery == DatabaseErrorRecovery.none)
        #expect(DatabaseErrorCategory.serverError.suggestedRecovery == DatabaseErrorRecovery.none)
        #expect(DatabaseErrorCategory.unknown.suggestedRecovery == DatabaseErrorRecovery.none)
    }

    @Test func everyCategoryHasLocalizationKey() {
        for category in DatabaseErrorCategory.allCases {
            #expect(!category.localizationKey.isEmpty)
        }
    }
}