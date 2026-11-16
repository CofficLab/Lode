import Foundation

/// 数据库插件的全局偏好设置（持久化到工作区 UserDefaults）。
///
/// 覆盖查询行数上限、新建连接的默认安全模式、编辑器字号与 SQL 格式化规则。
/// 各字段提供合理默认值；解码时对缺失键回退默认，保证旧版本存档可平滑升级。
public struct DatabaseSettings: Codable, Equatable, Sendable {
    /// 查询结果默认行数上限；0 表示沿用各引擎能力默认值。
    public var defaultQueryRowLimit: Int
    /// 新建连接的默认安全模式（``ConnectionSafeMode`` 原始值）。
    public var defaultSafeMode: String
    /// 编辑器字号（磅）；0 表示沿用系统默认字号。
    public var editorFontSize: Double
    /// SQL 关键字大小写：upper / lower / preserve。
    public var keywordCase: String
    /// 缩进宽度（空格数）。
    public var indentWidth: Int
    /// 用制表符缩进。
    public var useTabs: Bool
    /// 主要子句各占一行。
    public var clausePerLine: Bool
    /// SELECT/GROUP BY/ORDER BY 列表逐项换行。
    public var commaNewlineInList: Bool

    public init(
        defaultQueryRowLimit: Int = 0,
        defaultSafeMode: String = ConnectionSafeMode.off.rawValue,
        editorFontSize: Double = 0,
        keywordCase: String = "upper",
        indentWidth: Int = 2,
        useTabs: Bool = false,
        clausePerLine: Bool = true,
        commaNewlineInList: Bool = true
    ) {
        self.defaultQueryRowLimit = defaultQueryRowLimit
        self.defaultSafeMode = defaultSafeMode
        self.editorFontSize = editorFontSize
        self.keywordCase = keywordCase
        self.indentWidth = indentWidth
        self.useTabs = useTabs
        self.clausePerLine = clausePerLine
        self.commaNewlineInList = commaNewlineInList
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DatabaseSettings()
        defaultQueryRowLimit = try container.decodeIfPresent(Int.self, forKey: .defaultQueryRowLimit) ?? defaults.defaultQueryRowLimit
        defaultSafeMode = try container.decodeIfPresent(String.self, forKey: .defaultSafeMode) ?? defaults.defaultSafeMode
        editorFontSize = try container.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? defaults.editorFontSize
        keywordCase = try container.decodeIfPresent(String.self, forKey: .keywordCase) ?? defaults.keywordCase
        indentWidth = try container.decodeIfPresent(Int.self, forKey: .indentWidth) ?? defaults.indentWidth
        useTabs = try container.decodeIfPresent(Bool.self, forKey: .useTabs) ?? defaults.useTabs
        clausePerLine = try container.decodeIfPresent(Bool.self, forKey: .clausePerLine) ?? defaults.clausePerLine
        commaNewlineInList = try container.decodeIfPresent(Bool.self, forKey: .commaNewlineInList) ?? defaults.commaNewlineInList
    }

    /// 映射到格式化器选项；非法关键字大小写回退 upper，缩进宽度至少 1。
    public var formatterOptions: SQLFormatterOptions {
        let keyword: SQLFormatterOptions.KeywordCase
        switch keywordCase {
        case "lower": keyword = .lower
        case "preserve": keyword = .preserve
        default: keyword = .upper
        }
        return SQLFormatterOptions(
            keywordCase: keyword,
            indentWidth: max(1, indentWidth),
            useTabs: useTabs,
            clausePerLine: clausePerLine,
            commaNewlineInList: commaNewlineInList
        )
    }

    /// 映射到连接安全模式；无法识别的原始值回退 ``ConnectionSafeMode/off``。
    public var safeMode: ConnectionSafeMode {
        ConnectionSafeMode(rawValue: defaultSafeMode) ?? .off
    }
}