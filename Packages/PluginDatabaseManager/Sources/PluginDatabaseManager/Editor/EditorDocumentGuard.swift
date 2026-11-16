import Foundation
import ProviderEditor

/// 超大文档守卫：文档超过阈值时关闭高亮/折叠/解析，避免主线程被巨量文本拖垮。
///
/// 阈值以 UTF-16 码元计（与编辑器文本存储一致）。达到或超过阈值即视为超大文档：
/// 关闭语法高亮、折叠与 tree-sitter 解析，仅保留纯文本编辑，并向用户提示。
/// 阈值取自编辑器契约层 ``EditorDocumentLimits``，与宿主降级判定共用同一常量。
public enum EditorDocumentGuard {
    /// 超大文档阈值：2,000,000 个 UTF-16 码元（约 2MB ASCII）。
    public static let largeDocumentUTF16Threshold = EditorDocumentLimits.largeDocumentUTF16Threshold

    /// 守卫判定结果。
    public struct Decision: Sendable, Equatable {
        /// 是否启用语法高亮。
        public let highlightEnabled: Bool
        /// 是否启用代码折叠。
        public let foldEnabled: Bool
        /// 是否启用 tree-sitter 解析。
        public let parseEnabled: Bool
        /// 是否向用户显示「超大文档已降级」提示。
        public let showNotice: Bool

        public init(highlightEnabled: Bool, foldEnabled: Bool, parseEnabled: Bool, showNotice: Bool) {
            self.highlightEnabled = highlightEnabled
            self.foldEnabled = foldEnabled
            self.parseEnabled = parseEnabled
            self.showNotice = showNotice
        }
    }

    /// 按文档 UTF-16 长度判定是否降级。低于阈值全功能；达到/超过阈值关闭高亮/折叠/解析并提示。
    public static func evaluate(utf16Length: Int) -> Decision {
        let large = utf16Length >= largeDocumentUTF16Threshold
        return Decision(
            highlightEnabled: !large,
            foldEnabled: !large,
            parseEnabled: !large,
            showNotice: large
        )
    }

    /// 便捷判定：给定文本是否触发超大文档降级。
    public static func isLargeDocument(_ text: String) -> Bool {
        text.utf16.count >= largeDocumentUTF16Threshold
    }
}