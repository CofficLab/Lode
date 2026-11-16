import Foundation

/// 连接级安全模式。值存进 ``DatabaseConfig/options`` 的 `"safeMode"` 键，
/// 驱动层与写权限闸门据此决定写操作的处理方式。
///
/// 三档语义：
/// - ``off``：不拦截（默认，与历史行为一致）。
/// - ``confirmWrites``：所有写操作执行前弹确认。
/// - ``readOnly``：驱动层直接拒绝写语句（生产连接的硬保证）。
public enum ConnectionSafeMode: String, CaseIterable, Sendable {
    case off
    case confirmWrites = "confirm"
    case readOnly = "readOnly"

    public var displayTitle: String {
        switch self {
        case .off: return "Off"
        case .confirmWrites: return "Confirm Writes"
        case .readOnly: return "Read Only"
        }
    }

    public var helpText: String {
        switch self {
        case .off: return "No restrictions. Writes run immediately."
        case .confirmWrites: return "Ask for confirmation before every write."
        case .readOnly: return "Block all writes at the driver. Safe for production."
        }
    }
}

public extension DatabaseConfig {
    private static let safeModeKey = "safeMode"

    /// 当前配置的安全模式。未设置或无法识别时回退 ``ConnectionSafeMode/off``。
    var safeMode: ConnectionSafeMode {
        guard let raw = options?[Self.safeModeKey], let mode = ConnectionSafeMode(rawValue: raw) else {
            return .off
        }
        return mode
    }

    /// 返回一份应用了新安全模式的副本（``ConnectionSafeMode/off`` 移除该键，回退默认）。
    func withSafeMode(_ mode: ConnectionSafeMode) -> DatabaseConfig {
        var copy = self
        var opts = copy.options ?? [:]
        if mode == .off {
            opts.removeValue(forKey: Self.safeModeKey)
        } else {
            opts[Self.safeModeKey] = mode.rawValue
        }
        copy.options = opts.isEmpty ? nil : opts
        return copy
    }
}