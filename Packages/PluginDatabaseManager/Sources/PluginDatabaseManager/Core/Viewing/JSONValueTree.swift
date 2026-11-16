import Foundation

/// JSON 值类型（树节点_kind_）。
public enum JSONValueKind: String, Sendable {
    case object, array, string, number, bool, null
}

/// JSON 树的扁平前序节点：`id` 即数组下标，`subtreeEnd` 为子树结束下标（不含），
/// 折叠时可直接跳过整棵子树，渲染与搜索都不需要递归遍历对象图。
public struct JSONTreeNode: Sendable, Equatable, Identifiable {
    public let id: Int
    public let parent: Int?
    public let depth: Int
    /// 显示键：根为 `$`，对象键原样，数组元素为 `[i]`。
    public let key: String
    /// 复制用路径，如 `$.items[0].name`；特殊键走 `$['a.b']` 括号记法。
    public let path: String
    public let kind: JSONValueKind
    public let childCount: Int
    public let subtreeEnd: Int
    /// 标量全文（容器为 nil）；复制值时标量原样返回。
    public let scalar: String?
    /// 标量显示预览（截断 80 字符；容器为空串，由视图按 childCount 组装）。
    public let summary: String
}

/// 大 JSON 单元格查看器的纯函数核心：构建 / 可见行 / 搜索 / 复制值。
///
/// 全部为无隔离纯函数，可在 `Task.detached` 中构建（1MB 级 JSON 不占主线程）；
/// 节点数组 `Sendable`，构建完成后一次性交回主线程渲染。
public enum JSONValueTree {
    /// 解析 JSON 文本为前序节点数组；非法 JSON 返回 nil。
    public static func build(from text: String) -> [JSONTreeNode]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else { return nil }
        var nodes: [JSONTreeNode] = []
        walk(root, key: "$", path: "$", depth: 0, parent: nil, nodes: &nodes)
        return nodes
    }

    /// 当前展开状态下的可见行（前序，折叠节点跳过子树）。
    public static func visibleRows(_ nodes: [JSONTreeNode], expanded: Set<Int>) -> [Int] {
        var rows: [Int] = []
        var index = 0
        while index < nodes.count {
            rows.append(index)
            let node = nodes[index]
            if node.childCount > 0 && !expanded.contains(node.id) {
                index = node.subtreeEnd
            } else {
                index += 1
            }
        }
        return rows
    }

    /// 搜索键 / 路径 / 标量值（大小写不敏感），返回命中节点 id（前序）。
    public static func search(_ nodes: [JSONTreeNode], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return nodes.filter { node in
            node.key.lowercased().contains(needle)
                || node.path.lowercased().contains(needle)
                || node.scalar?.lowercased().contains(needle) == true
        }.map(\.id)
    }

    /// 复制值：标量原样返回；容器重建子树 JSON（键排序，语义等价）。
    public static func copyValue(_ nodes: [JSONTreeNode], at id: Int) -> String? {
        guard id >= 0, id < nodes.count else { return nil }
        let node = nodes[id]
        if node.kind != .object && node.kind != .array { return node.scalar ?? "" }
        let object = reconstruct(nodes, at: id)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - Private

    private static func walk(_ value: Any, key: String, path: String, depth: Int, parent: Int?, nodes: inout [JSONTreeNode]) {
        let id = nodes.count
        if let object = value as? [String: Any] {
            nodes.append(JSONTreeNode(
                id: id, parent: parent, depth: depth, key: key, path: path,
                kind: .object, childCount: 0, subtreeEnd: id + 1, scalar: nil, summary: ""))
            for childKey in object.keys.sorted() {
                walk(object[childKey] as Any, key: childKey, path: childPath(path, key: childKey),
                     depth: depth + 1, parent: id, nodes: &nodes)
            }
            nodes[id] = JSONTreeNode(
                id: id, parent: parent, depth: depth, key: key, path: path,
                kind: .object, childCount: object.count, subtreeEnd: nodes.count, scalar: nil, summary: "")
        } else if let array = value as? [Any] {
            nodes.append(JSONTreeNode(
                id: id, parent: parent, depth: depth, key: key, path: path,
                kind: .array, childCount: 0, subtreeEnd: id + 1, scalar: nil, summary: ""))
            for (index, element) in array.enumerated() {
                walk(element, key: "[\(index)]", path: "\(path)[\(index)]",
                     depth: depth + 1, parent: id, nodes: &nodes)
            }
            nodes[id] = JSONTreeNode(
                id: id, parent: parent, depth: depth, key: key, path: path,
                kind: .array, childCount: array.count, subtreeEnd: nodes.count, scalar: nil, summary: "")
        } else {
            let (kind, scalar) = scalarText(value)
            let summary = scalar.count > 80 ? String(scalar.prefix(80)) + "…" : scalar
            nodes.append(JSONTreeNode(
                id: id, parent: parent, depth: depth, key: key, path: path,
                kind: kind, childCount: 0, subtreeEnd: id + 1, scalar: scalar, summary: summary))
        }
    }

    private static func scalarText(_ value: Any) -> (JSONValueKind, String) {
        if value is NSNull { return (.null, "null") }
        if let string = value as? String { return (.string, string) }
        if let number = value as? NSNumber {
            // NSNumber 的 as? Bool 对 0/1 也成立，按 CFBoolean 类型区分。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return (.bool, number.boolValue ? "true" : "false")
            }
            return (.number, number.stringValue)
        }
        return (.string, String(describing: value))
    }

    private static func childPath(_ path: String, key: String) -> String {
        let isIdentifier = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && !(key.first?.isNumber ?? false)
        if isIdentifier { return "\(path).\(key)" }
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "\(path)['\(escaped)']"
    }

    private static func reconstruct(_ nodes: [JSONTreeNode], at id: Int) -> Any {
        let node = nodes[id]
        switch node.kind {
        case .object:
            var object: [String: Any] = [:]
            var index = id + 1
            while index < node.subtreeEnd {
                let child = nodes[index]
                object[child.key] = reconstruct(nodes, at: index)
                index = child.subtreeEnd
            }
            return object
        case .array:
            var array: [Any] = []
            var index = id + 1
            while index < node.subtreeEnd {
                let child = nodes[index]
                array.append(reconstruct(nodes, at: index))
                index = child.subtreeEnd
            }
            return array
        case .string:
            return node.scalar ?? ""
        case .number:
            let scalar = node.scalar ?? "0"
            return Int(scalar) ?? Double(scalar) ?? scalar
        case .bool:
            return node.scalar == "true"
        case .null:
            return NSNull()
        }
    }
}