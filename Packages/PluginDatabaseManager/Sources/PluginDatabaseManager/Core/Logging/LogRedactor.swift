import Foundation

/// 日志脱敏过滤器：在日志写出前移除凭据与机密。
///
/// 纯函数、无副作用，覆盖连接 URL userinfo、键值对、JSON 字段、Bearer 令牌与
/// SQL `IDENTIFIED BY` 等常见凭据载体。宁可过度脱敏也不泄露：命中敏感键的值一律
/// 替换为 ``marker``。不命中敏感模式的普通文本原样保留。
public enum LogRedactor {
    /// 替换敏感值的占位标记。
    public static let marker = "[redacted]"

    /// 敏感键名（大小写不敏感）。长键在前，避免短键先行匹配。
    private static let sensitiveKeys = [
        "password", "passwd", "pwd", "secret", "access_token", "refresh_token",
        "api_key", "apikey", "token", "authorization", "credential", "private_key",
        "ssh_password", "auth",
    ]

    private static let keyAlternation = sensitiveKeys.joined(separator: "|")

    /// URL userinfo：`scheme://user:password@host` → `scheme://user:[redacted]@host`。
    private static let urlUserInfo = try! NSRegularExpression(
        pattern: #"([a-zA-Z][a-zA-Z0-9+.\-]*://)([^/@\s:]*):([^/@\s]*)@"#
    )

    /// JSON quoted 键值：`"password":"value"`（值含转义引号也安全）。
    private static let jsonField = try! NSRegularExpression(
        pattern: #"("(?:\#(keyAlternation))"\s*:\s*)"(?:[^"\\]|\\.)*""#,
        options: [.caseInsensitive]
    )

    /// Bearer 令牌：`Bearer abc.def.ghi`。
    private static let bearer = try! NSRegularExpression(
        pattern: #"(bearer\s+)[A-Za-z0-9._~+/\-]+=*"#,
        options: [.caseInsensitive]
    )

    /// Authorization 头：`Authorization: Basic dXNlcjpwYXNz` / `authorization=Bearer xyz`。
    /// 连同可选的认证方案词（Basic/Bearer 等）与凭据一并脱敏。
    private static let authorization = try! NSRegularExpression(
        pattern: #"\b(authorization)(\s*[:=]\s*)(?:[A-Za-z][A-Za-z0-9._-]*\s+)?[^\s,;&"']+"#,
        options: [.caseInsensitive]
    )

    /// SQL `IDENTIFIED BY 'value'`。
    private static let identifiedBy = try! NSRegularExpression(
        pattern: #"(IDENTIFIED\s+BY\s+)'(?:[^'\\]|\\.)*'"#,
        options: [.caseInsensitive]
    )

    /// 裸键值对：`password=value` / `password: value`（值止于空白或 , ; & 引号）。
    private static let keyValue = try! NSRegularExpression(
        pattern: #"\b(\#(keyAlternation))(\s*[:=]\s*)([^\s,;&"']+)"#,
        options: [.caseInsensitive]
    )

    /// 对消息脱敏；无敏感模式时原样返回。
    public static func redact(_ message: String) -> String {
        guard !message.isEmpty else { return message }
        var result = message
        result = replace(urlUserInfo, in: result, with: "$1$2:\(marker)@")
        result = replace(jsonField, in: result, with: "$1\"\(marker)\"")
        result = replace(bearer, in: result, with: "$1\(marker)")
        result = replace(authorization, in: result, with: "$1$2\(marker)")
        result = replace(identifiedBy, in: result, with: "$1'\(marker)'")
        result = replace(keyValue, in: result, with: "$1$2\(marker)")
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}