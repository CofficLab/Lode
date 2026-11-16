import Foundation

#if canImport(MySQLNIO)
import MySQLNIO
#endif
#if canImport(PostgresNIO)
import PostgresNIO
#endif
#if canImport(Network)
import Network
#endif
#if canImport(NIOCore)
import NIOCore
#endif

/// 数据库错误的语义分类，用于本地化展示与恢复动作推荐。
public enum DatabaseErrorCategory: String, Sendable, CaseIterable {
    /// 主机/端口不可达、DNS 失败、服务未启动。
    case networkUnreachable
    /// 用户名或密码错误。
    case authenticationFailed
    /// 目标数据库不存在。
    case databaseNotFound
    /// 已认证但权限不足。
    case permissionDenied
    /// SQL 语法或对象名错误。
    case syntaxError
    /// 连接或语句超时。
    case timeout
    /// 用户主动取消。
    case cancelled
    /// 已建立的连接中途断开（服务端重启、被 KILL、网络中断）。
    case connectionLost
    /// 服务端返回的其他错误。
    case serverError
    /// 无法归类的错误。
    case unknown

    /// 本地化分类标题的字符串表 key（英文原文）。
    public var localizationKey: String {
        switch self {
        case .networkUnreachable: return "Cannot reach the database server"
        case .authenticationFailed: return "Authentication failed"
        case .databaseNotFound: return "Database not found"
        case .permissionDenied: return "Permission denied"
        case .syntaxError: return "SQL error"
        case .timeout: return "Connection timed out"
        case .cancelled: return "Query cancelled"
        case .connectionLost: return "Connection lost"
        case .serverError: return "Database server error"
        case .unknown: return "Operation failed"
        }
    }

    /// 该分类推荐的恢复动作。
    public var suggestedRecovery: DatabaseErrorRecovery {
        switch self {
        case .networkUnreachable, .timeout, .connectionLost:
            return .retry
        case .authenticationFailed, .databaseNotFound, .permissionDenied:
            return .editConnection
        case .syntaxError, .cancelled, .serverError, .unknown:
            return .none
        }
    }
}

/// 错误条上可执行的恢复动作。
public enum DatabaseErrorRecovery: Sendable, Equatable {
    /// 重试：未连接时重连，已连接时重跑上一条语句。
    case retry
    /// 打开当前连接的编辑表单。
    case editConnection
    case none
}

/// 分类后的错误：语义类别 + 原始细节文本。
public struct ClassifiedDatabaseError: Sendable, Equatable {
    public let category: DatabaseErrorCategory
    /// 原始错误描述（服务端消息），保留细节供用户排查。
    public let detail: String

    public init(category: DatabaseErrorCategory, detail: String) {
        self.category = category
        self.detail = detail
    }

    public var recovery: DatabaseErrorRecovery { category.suggestedRecovery }
}

/// 把各驱动抛出的原始错误归一到 ``DatabaseErrorCategory``。
///
/// 优先识别结构化错误（MySQL 错误码、PostgreSQL SQLSTATE、网络错误），
/// 最后退回文本特征匹配（覆盖 SQLite errmsg 与已被包装成字符串的错误）。
public enum DatabaseErrorClassifier {
    public static func classify(_ error: any Error) -> ClassifiedDatabaseError {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return ClassifiedDatabaseError(category: category(of: error), detail: detail)
    }

    static func category(of error: any Error) -> DatabaseErrorCategory {
        if let dbError = error as? DatabaseError {
            switch dbError {
            case .cancelled:
                return .cancelled
            case .driverNotFound, .invalidConfiguration, .notImplemented:
                return .unknown
            case .connectionFailed(let message), .queryFailed(let message), .transactionFailed(let message):
                return categoryFromText(message)
            }
        }
        #if canImport(MySQLNIO)
        if let mysqlError = error as? MySQLError {
            return category(of: mysqlError)
        }
        #endif
        #if canImport(PostgresNIO)
        if let pgError = error as? PSQLError {
            return category(of: pgError)
        }
        #endif
        #if canImport(Network)
        if let nwError = error as? NWError {
            return category(of: nwError)
        }
        #endif
        #if canImport(NIOCore)
        if let ioError = error as? IOError {
            return category(ofErrno: ioError.errnoCode)
        }
        #endif
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
            let nested = category(of: underlying)
            if nested != .unknown { return nested }
        }
        let fromDescription = categoryFromText(error.localizedDescription)
        if fromDescription != .unknown { return fromDescription }
        return categoryFromText(String(describing: error))
    }

    #if canImport(MySQLNIO)
    static func category(of error: MySQLError) -> DatabaseErrorCategory {
        switch error {
        case .server(let packet):
            return category(ofMySQLErrorCode: packet.errorCode)
        case .invalidSyntax:
            return .syntaxError
        case .duplicateEntry:
            return .serverError
        case .closed:
            return .connectionLost
        case .secureConnectionRequired, .unsupportedAuthPlugin, .authPluginDataError,
             .missingOrInvalidAuthMoreDataStatusTag, .missingOrInvalidAuthPluginInlineCommand,
             .missingAuthPluginInlineData:
            return .authenticationFailed
        case .unsupportedServer, .protocolError:
            return .serverError
        }
    }

    static func category(ofMySQLErrorCode code: MySQLProtocol.ErrorCode) -> DatabaseErrorCategory {
        switch code {
        case .ACCESS_DENIED_ERROR, .NOT_SUPPORTED_AUTH_MODE, .HANDSHAKE_ERROR:
            return .authenticationFailed
        case .BAD_DB_ERROR, .NO_DB_ERROR:
            return .databaseNotFound
        case .DBACCESS_DENIED_ERROR, .TABLEACCESS_DENIED_ERROR, .SPECIFIC_ACCESS_DENIED_ERROR:
            return .permissionDenied
        case .PARSE_ERROR, .EMPTY_QUERY, .BAD_FIELD_ERROR, .NO_SUCH_TABLE, .BAD_TABLE_ERROR:
            return .syntaxError
        case .QUERY_INTERRUPTED:
            return .cancelled
        case .LOCK_WAIT_TIMEOUT, .QUERY_TIMEOUT:
            return .timeout
        case .CONN_HOST_ERROR, .CONNECTION_ERROR, .UNKNOWN_HOST, .SOCKET_CREATE_ERROR, .IPSOCK_ERROR_CLIENT:
            return .networkUnreachable
        case .SERVER_GONE_ERROR, .SERVER_LOST, .SERVER_SHUTDOWN, .SERVER_HANDSHAKE_ERR:
            return .connectionLost
        default:
            return .serverError
        }
    }
    #endif

    #if canImport(PostgresNIO)
    static func category(of error: PSQLError) -> DatabaseErrorCategory {
        switch error.code {
        case .queryCancelled:
            return .cancelled
        case .serverClosedConnection, .clientClosedConnection, .uncleanShutdown:
            return .connectionLost
        case .connectionError:
            return .networkUnreachable
        case .unsupportedAuthMechanism, .authMechanismRequiresPassword, .saslError:
            return .authenticationFailed
        case .server:
            if let sqlState = error.serverInfo?[.sqlState] {
                return category(ofSQLState: sqlState)
            }
            return .serverError
        default:
            return .serverError
        }
    }
    #endif

    /// PostgreSQL SQLSTATE → 分类。独立成纯函数便于单元测试。
    static func category(ofSQLState sqlState: String) -> DatabaseErrorCategory {
        if sqlState == "57014" { return .cancelled }
        if sqlState == "28P01" || sqlState == "28000" { return .authenticationFailed }
        if sqlState == "3D000" { return .databaseNotFound }
        if sqlState == "42501" { return .permissionDenied }
        if sqlState == "42601" || sqlState == "42703" || sqlState == "42P01" { return .syntaxError }
        if sqlState == "57P01" || sqlState == "57P02" || sqlState == "57P03" { return .connectionLost }
        if sqlState.hasPrefix("08") { return .connectionLost }
        if sqlState.hasPrefix("53") || sqlState == "55P03" || sqlState == "55006" { return .serverError }
        return .serverError
    }

    #if canImport(Network)
    static func category(of error: NWError) -> DatabaseErrorCategory {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EADDRNOTAVAIL:
                return .networkUnreachable
            case .ETIMEDOUT:
                return .timeout
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECONNABORTED:
                return .connectionLost
            default:
                return .unknown
            }
        case .dns:
            return .networkUnreachable
        case .tls:
            return .authenticationFailed
        @unknown default:
            return .unknown
        }
    }
    #endif

    #if canImport(NIOCore)
    /// NIO 的 POSIX errno 错误（MySQL/PG 连接失败常以 IOError 抛出）。
    static func category(ofErrno errno: CInt) -> DatabaseErrorCategory {
        switch errno {
        case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, ENETDOWN, EADDRNOTAVAIL:
            return .networkUnreachable
        case ETIMEDOUT:
            return .timeout
        case ECONNRESET, EPIPE, ENOTCONN, ECONNABORTED:
            return .connectionLost
        default:
            return .unknown
        }
    }
    #endif

    /// 文本特征兜底：覆盖 SQLite errmsg、被包装成字符串的错误与未知驱动。
    static func categoryFromText(_ text: String) -> DatabaseErrorCategory {
        let lower = text.lowercased()
        if lower.contains("cancel") { return .cancelled }
        if lower.contains("access denied") || lower.contains("password authentication failed")
            || lower.contains("authentication failed") || lower.contains("wrong password")
            || lower.contains("using password: yes") || lower.contains("using password: no") {
            return .authenticationFailed
        }
        if lower.contains("unknown database") || lower.contains("does not exist") && lower.contains("database") {
            return .databaseNotFound
        }
        if lower.contains("permission denied") || lower.contains("command denied")
            || lower.contains("access denied for user") && lower.contains("to database") {
            return .permissionDenied
        }
        if lower.contains("syntax error") || lower.contains("syntax") || lower.contains("no such table")
            || lower.contains("no such column") || lower.contains("doesn't exist") || lower.contains("unknown column") {
            return .syntaxError
        }
        if lower.contains("timed out") || lower.contains("timeout") { return .timeout }
        if lower.contains("connection refused") || lower.contains("can't connect")
            || lower.contains("could not connect") || lower.contains("unreachable")
            || lower.contains("name or service not known") || lower.contains("nodename nor servname")
            || lower.contains("unable to open database") {
            return .networkUnreachable
        }
        if lower.contains("server has gone away") || lower.contains("lost connection")
            || lower.contains("connection reset") || lower.contains("broken pipe")
            || lower.contains("connection closed") || lower.contains("closed the connection")
            || lower.contains("terminating connection") || lower.contains("server closed the connection")
            || lower.contains("not connected") || lower.contains("connection is closed") {
            return .connectionLost
        }
        if lower.contains("readonly") || lower.contains("read-only") || lower.contains("locked") {
            return .serverError
        }
        return .unknown
    }
}