import CoreGraphics
import Foundation

/// ER 图的一列（精简到绘图所需）。
struct ERColumn: Hashable, Sendable {
    let name: String
    let dataType: String
    let isPrimaryKey: Bool
    let isForeignKey: Bool
    let isNullable: Bool
}

/// ER 图节点：一张表或视图。`id` 为 schema 限定键（`schema.name`，无 schema 时即表名）。
struct ERNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let schema: String?
    let columns: [ERColumn]
    let rowCount: Int?
    /// 由布局算法赋值（左上角坐标）。
    var position: CGPoint = .zero
}

/// ER 图关系边：源表外键 → 被引用表。
struct EREdge: Identifiable, Hashable, Sendable {
    let id: String
    let fromNode: String
    let toNode: String
    let fromColumns: [String]
    let toColumns: [String]
    let name: String
    let onDelete: String?
    let onUpdate: String?
}

/// 只读 ER 图：节点 + 边 + 画布尺寸。
struct ERDiagram: Sendable {
    var nodes: [ERNode]
    var edges: [EREdge]
    var canvasSize: CGSize = .zero

    func node(id: String) -> ERNode? {
        nodes.first { $0.id == id }
    }
}

/// 从 introspection 的表结构集合构建 ER 图。纯函数，便于离线测试。
enum ERDiagramBuilder {
    static func nodeID(schema: String?, name: String) -> String {
        if let schema, !schema.isEmpty { return "\(schema).\(name)" }
        return name
    }

    static func build(from schemas: [TableSchema]) -> ERDiagram {
        // 按节点键排序，保证构建与布局确定性。
        let ordered = schemas.sorted {
            nodeID(schema: $0.table.schema, name: $0.table.name)
                < nodeID(schema: $1.table.schema, name: $1.table.name)
        }

        var nodesByID: [String: ERNode] = [:]
        var edges: [EREdge] = []
        var edgeIDs: Set<String> = []

        for schema in ordered {
            let sourceID = nodeID(schema: schema.table.schema, name: schema.table.name)
            let fkColumns = Set(schema.foreignKeys.flatMap(\.columns))
            let columns = schema.columns
                .sorted { $0.position < $1.position }
                .map {
                    ERColumn(
                        name: $0.name,
                        dataType: $0.dataType,
                        isPrimaryKey: $0.isPrimaryKey,
                        isForeignKey: fkColumns.contains($0.name),
                        isNullable: $0.isNullable
                    )
                }
            nodesByID[sourceID] = ERNode(
                id: sourceID,
                name: schema.table.name,
                schema: schema.table.schema,
                columns: columns,
                rowCount: schema.table.rowCount
            )

            for fk in schema.foreignKeys {
                // 外键目标表默认与源表同 schema。
                let targetID = nodeID(schema: schema.table.schema, name: fk.referencesTable)
                let edgeID = "\(sourceID)->\(targetID):\(fk.name):\(fk.columns.joined(separator: ","))"
                guard !edgeIDs.contains(edgeID) else { continue }
                edgeIDs.insert(edgeID)
                edges.append(EREdge(
                    id: edgeID,
                    fromNode: sourceID,
                    toNode: targetID,
                    fromColumns: fk.columns,
                    toColumns: fk.referencesColumns,
                    name: fk.name,
                    onDelete: fk.onDelete,
                    onUpdate: fk.onUpdate
                ))
                // 被引用但未被描述的表：补一个空列 stub 节点，保证边有落点。
                if nodesByID[targetID] == nil {
                    nodesByID[targetID] = ERNode(
                        id: targetID,
                        name: fk.referencesTable,
                        schema: schema.table.schema,
                        columns: [],
                        rowCount: nil
                    )
                }
            }
        }

        var diagram = ERDiagram(
            nodes: nodesByID.values.sorted { $0.id < $1.id },
            edges: edges.sorted { $0.id < $1.id }
        )
        ERLayout.layout(&diagram)
        return diagram
    }
}

/// 确定性分层布局：按「最长外键引用链」分层（环守卫），层内按 id 排序，垂直居中对齐。
/// 同一输入集合永远得到同一坐标，便于测试与导出复现。
enum ERLayout {
    static let nodeWidth: Double = 220
    static let headerHeight: Double = 30
    static let rowHeight: Double = 18
    static let nodePadding: Double = 10
    static let horizontalGap: Double = 90
    static let verticalGap: Double = 36
    static let margin: Double = 40

    static func nodeHeight(_ node: ERNode) -> Double {
        headerHeight + max(1, Double(node.columns.count)) * rowHeight + nodePadding
    }

    static func layout(_ diagram: inout ERDiagram) {
        guard !diagram.nodes.isEmpty else {
            diagram.canvasSize = .zero
            return
        }

        // 邻接表：源 → 目标集合（去重，避免复合外键重复影响分层）。
        var adjacency: [String: Set<String>] = [:]
        for edge in diagram.edges {
            adjacency[edge.fromNode, default: []].insert(edge.toNode)
        }

        var layers: [String: Int] = [:]
        var visiting: Set<String> = []
        func layer(of id: String) -> Int {
            if let cached = layers[id] { return cached }
            if visiting.contains(id) { return 0 } // 环：截断回边
            visiting.insert(id)
            let targets = adjacency[id] ?? []
            let value = targets.isEmpty ? 0 : 1 + (targets.map { layer(of: $0) }.max() ?? 0)
            visiting.remove(id)
            layers[id] = value
            return value
        }

        let sortedIDs = diagram.nodes.map(\.id).sorted()
        for id in sortedIDs { _ = layer(of: id) }

        var byLayer: [Int: [String]] = [:]
        for id in sortedIDs {
            byLayer[layers[id] ?? 0, default: []].append(id)
        }
        let maxLayer = byLayer.keys.max() ?? 0
        let nodeByID = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, $0) })

        func columnHeight(_ ids: [String]) -> Double {
            let heights = ids.compactMap { nodeByID[$0] }.map { nodeHeight($0) }
            let sum = heights.reduce(0, +)
            let gaps = Double(max(0, heights.count - 1)) * verticalGap
            return sum + gaps
        }

        let tallest = (0...maxLayer).map { columnHeight(byLayer[$0] ?? []) }.max() ?? 0

        for layerIndex in 0...maxLayer {
            let ids = (byLayer[layerIndex] ?? []).sorted()
            let x = margin + Double(layerIndex) * (nodeWidth + horizontalGap)
            var y = margin + (tallest - columnHeight(ids)) / 2
            for id in ids {
                guard let index = diagram.nodes.firstIndex(where: { $0.id == id }) else { continue }
                diagram.nodes[index].position = CGPoint(x: x, y: y)
                y += nodeHeight(diagram.nodes[index]) + verticalGap
            }
        }

        let width = margin * 2 + Double(maxLayer + 1) * nodeWidth + Double(maxLayer) * horizontalGap
        let height = margin * 2 + tallest
        diagram.canvasSize = CGSize(width: width, height: height)
    }
}