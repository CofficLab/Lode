import Foundation

/// 连接的颜色标签。值存进 ``DatabaseConfig/options`` 的 `"color"` 键，
/// 侧边栏连接行据此显示一个彩色圆点，便于按环境/用途快速区分（如生产=红、测试=绿）。
///
/// 模型本身不依赖 UI：具体颜色由视图层映射到 LumiUI 主题语义色
/// （blue→primary、green→success、orange→warning、red→error、purple→primarySecondary、cyan→info）。
public enum ConnectionColor: String, CaseIterable, Sendable {
    case none
    case blue
    case green
    case orange
    case red
    case purple
    case cyan

    public var displayTitle: String {
        switch self {
        case .none: return "None"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .red: return "Red"
        case .purple: return "Purple"
        case .cyan: return "Cyan"
        }
    }
}

public extension DatabaseConfig {
    private static let groupKey = "group"
    private static let colorKey = "color"
    private static let startupSQLKey = "startupSQL"

    /// 连接所属分组名（侧边栏据此分区）。未设置或全空白时返回 nil（视为未分组）。
    var group: String? {
        guard let raw = options?[Self.groupKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// 返回一份应用了新分组名的副本（nil 或全空白移除该键，回退未分组）。
    func withGroup(_ group: String?) -> DatabaseConfig {
        var copy = self
        var opts = copy.options ?? [:]
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            opts.removeValue(forKey: Self.groupKey)
        } else {
            opts[Self.groupKey] = trimmed
        }
        copy.options = opts.isEmpty ? nil : opts
        return copy
    }

    /// 当前配置的颜色标签。未设置或无法识别时回退 ``ConnectionColor/none``。
    var connectionColor: ConnectionColor {
        guard let raw = options?[Self.colorKey], let color = ConnectionColor(rawValue: raw) else {
            return .none
        }
        return color
    }

    /// 返回一份应用了新颜色标签的副本（``ConnectionColor/none`` 移除该键，回退默认）。
    func withConnectionColor(_ color: ConnectionColor) -> DatabaseConfig {
        var copy = self
        var opts = copy.options ?? [:]
        if color == .none {
            opts.removeValue(forKey: Self.colorKey)
        } else {
            opts[Self.colorKey] = color.rawValue
        }
        copy.options = opts.isEmpty ? nil : opts
        return copy
    }

    /// 连接级 startup SQL：每次连接成功后自动执行的会话引导脚本（可多语句）。
    /// 未设置或全空白时返回 nil。外层空白被 trim，内部换行/分号原样保留。
    var startupSQL: String? {
        guard let raw = options?[Self.startupSQLKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// 返回一份应用了新 startup SQL 的副本（nil 或全空白移除该键）。
    func withStartupSQL(_ sql: String?) -> DatabaseConfig {
        var copy = self
        var opts = copy.options ?? [:]
        let trimmed = sql?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            opts.removeValue(forKey: Self.startupSQLKey)
        } else {
            opts[Self.startupSQLKey] = trimmed
        }
        copy.options = opts.isEmpty ? nil : opts
        return copy
    }
}