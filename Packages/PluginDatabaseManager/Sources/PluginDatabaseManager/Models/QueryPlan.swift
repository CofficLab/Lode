import Foundation

/// EXPLAIN 计划树的一个节点。统一三引擎（PG/MySQL/SQLite）的展示字段：
/// 操作类型、关系/索引、估算代价与行数、ANALYZE 实际时间与循环、过滤条件。
struct QueryPlanNode: Identifiable, Hashable, Sendable {
    /// 在计划树中稳定的路径键（如 "0"、"0.1"），SQLite 用其原生 id。
    let id: String
    /// 操作类型：PG 的 Node Type、MySQL 的 access_type、SQLite 的 detail 文本。
    var operation: String
    var relation: String?
    var index: String?
    var alias: String?
    var estimatedRows: Double?
    var startupCost: Double?
    var estimatedTotalCost: Double?
    var actualRows: Double?
    var actualTotalTimeMs: Double?
    var actualLoops: Int?
    var filter: String?
    /// 引擎特有的补充说明（MySQL access_type/key/filtered、SQLite 原始 detail 等）。
    var details: [String]
    var children: [QueryPlanNode]

    init(
        id: String,
        operation: String,
        relation: String? = nil,
        index: String? = nil,
        alias: String? = nil,
        estimatedRows: Double? = nil,
        startupCost: Double? = nil,
        estimatedTotalCost: Double? = nil,
        actualRows: Double? = nil,
        actualTotalTimeMs: Double? = nil,
        actualLoops: Int? = nil,
        filter: String? = nil,
        details: [String] = [],
        children: [QueryPlanNode] = []
    ) {
        self.id = id
        self.operation = operation
        self.relation = relation
        self.index = index
        self.alias = alias
        self.estimatedRows = estimatedRows
        self.startupCost = startupCost
        self.estimatedTotalCost = estimatedTotalCost
        self.actualRows = actualRows
        self.actualTotalTimeMs = actualTotalTimeMs
        self.actualLoops = actualLoops
        self.filter = filter
        self.details = details
        self.children = children
    }

    /// 用于瓶颈排序的权重：ANALYZE 实际总时间×循环优先，否则估算总代价，再否则估算行数。
    var bottleneckWeight: Double {
        if let actualTotalTimeMs {
            return actualTotalTimeMs * Double(max(1, actualLoops ?? 1))
        }
        if let estimatedTotalCost { return estimatedTotalCost }
        return estimatedRows ?? 0
    }
}

/// 一次 EXPLAIN 的结果：计划树根节点集合 + 引擎/ANALYZE 标记 + 规划/执行耗时。
/// 解析失败时保留 ``rawText`` 供 UI 原样展示，绝不丢信息。
struct QueryPlan: Sendable {
    var engine: DatabaseType
    var analyze: Bool
    var roots: [QueryPlanNode]
    var planningTimeMs: Double?
    var executionTimeMs: Double?
    var rawText: String?

    init(
        engine: DatabaseType,
        analyze: Bool = false,
        roots: [QueryPlanNode] = [],
        planningTimeMs: Double? = nil,
        executionTimeMs: Double? = nil,
        rawText: String? = nil
    ) {
        self.engine = engine
        self.analyze = analyze
        self.roots = roots
        self.planningTimeMs = planningTimeMs
        self.executionTimeMs = executionTimeMs
        self.rawText = rawText
    }

    var isEmpty: Bool { roots.isEmpty }

    /// 深度优先遍历全部节点。
    func allNodes() -> [QueryPlanNode] {
        var result: [QueryPlanNode] = []
        func walk(_ node: QueryPlanNode) {
            result.append(node)
            node.children.forEach(walk)
        }
        roots.forEach(walk)
        return result
    }

    /// 瓶颈节点 id：权重最大者（实际时间/代价/行数）。空计划返回 nil。
    var bottleneckNodeID: String? {
        allNodes().max { $0.bottleneckWeight < $1.bottleneckWeight }?.id
    }
}