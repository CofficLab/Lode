import Foundation

/// 命名参数的面板绑定值：类型 + 文本输入 + NULL 开关。
///
/// ``isSatisfied`` 判定是否已提供可用值（NULL 视为已提供）；
/// ``databaseValue`` 把输入按类型转成驱动绑定值，缺值或无法解析时为 nil。
public struct QueryParameterBinding: Sendable, Equatable {
    /// 参数类型。
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case text, integer, real, boolean
        public var id: String { rawValue }
    }

    public var kind: Kind
    /// 原始文本输入（text 类型按原样绑定，其余类型解析时去除首尾空白）。
    public var text: String
    /// 是否绑定 SQL NULL（优先于文本输入）。
    public var isNull: Bool

    public init(kind: Kind = .text, text: String = "", isNull: Bool = false) {
        self.kind = kind
        self.text = text
        self.isNull = isNull
    }

    /// 是否已提供值：NULL 或非空文本。空文本视为缺值，执行前拦截。
    public var isSatisfied: Bool { isNull || !text.isEmpty }

    /// 按类型转换的绑定值；缺值或解析失败返回 nil。
    public var databaseValue: DatabaseValue? {
        if isNull { return .null }
        guard !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text:
            return .string(text)
        case .integer:
            return Int(trimmed).map { DatabaseValue.integer($0) }
        case .real:
            return Double(trimmed).map { DatabaseValue.double($0) }
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "t", "yes", "y", "1": return .bool(true)
            case "false", "f", "no", "n", "0": return .bool(false)
            default: return nil
            }
        }
    }
}