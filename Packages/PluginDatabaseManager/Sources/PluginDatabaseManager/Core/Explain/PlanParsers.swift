import Foundation

// EXPLAIN 计划解析器：三引擎各自把原生输出转成统一的 ``QueryPlan`` 树。
// 全部为纯函数，离线可测；解析失败时保留 rawText，UI 原样展示不丢信息。

// MARK: - JSON 取值助手

private func planDouble(_ any: Any?) -> Double? {
    guard let any else { return nil }
    if let d = any as? Double { return d }
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String { return Double(s) }
    return nil
}

private func planInt(_ any: Any?) -> Int? {
    guard let any else { return nil }
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String { return Int(s) }
    return nil
}

private func planString(_ any: Any?) -> String? {
    guard let any else { return nil }
    if let s = any as? String { return s }
    if let n = any as? NSNumber { return n.stringValue }
    return nil
}

private func planBool(_ any: Any?) -> Bool? {
    guard let any else { return nil }
    if let b = any as? Bool { return b }
    if let n = any as? NSNumber { return n.boolValue }
    return nil
}

// MARK: - PostgreSQL（EXPLAIN (FORMAT JSON)）

enum PostgreSQLPlanParser {
    static func parse(_ text: String, analyze: Bool) -> QueryPlan {
        var plan = QueryPlan(engine: .postgresql, analyze: analyze, rawText: text)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return plan }
        let top: [String: Any]?
        if let array = object as? [[String: Any]] {
            top = array.first
        } else {
            top = object as? [String: Any]
        }
        guard let top else { return plan }
        plan.planningTimeMs = planDouble(top["Planning Time"])
        plan.executionTimeMs = planDouble(top["Execution Time"])
        if let planDict = top["Plan"] as? [String: Any] {
            plan.roots = [parseNode(planDict, path: "0")]
        }
        return plan
    }

    static func parseNode(_ dict: [String: Any], path: String) -> QueryPlanNode {
        var details: [String] = []
        for key in ["Strategy", "Partial Mode", "Join Type", "Parent Relationship", "Index Cond", "Hash Cond", "Merge Cond", "Recheck Cond", "Sort Key", "Group Key"] {
            if let value = dict[key] {
                if let s = value as? String {
                    details.append("\(key): \(s)")
                } else if let arr = value as? [String] {
                    details.append("\(key): \(arr.joined(separator: ", "))")
                }
            }
        }
        if planBool(dict["Parallel Aware"]) == true { details.append("Parallel Aware") }
        let children = (dict["Plans"] as? [[String: Any]] ?? []).enumerated().map { index, child in
            parseNode(child, path: "\(path).\(index)")
        }
        return QueryPlanNode(
            id: path,
            operation: planString(dict["Node Type"]) ?? "Plan",
            relation: planString(dict["Relation Name"]),
            index: planString(dict["Index Name"]),
            alias: planString(dict["Alias"]),
            estimatedRows: planDouble(dict["Plan Rows"]),
            startupCost: planDouble(dict["Startup Cost"]),
            estimatedTotalCost: planDouble(dict["Total Cost"]),
            actualRows: planDouble(dict["Actual Rows"]),
            actualTotalTimeMs: planDouble(dict["Actual Total Time"]),
            actualLoops: planInt(dict["Actual Loops"]),
            filter: planString(dict["Filter"]),
            details: details,
            children: children
        )
    }
}

// MARK: - MySQL（EXPLAIN FORMAT=JSON，表格回退）

enum MySQLPlanParser {
    static func parseJSON(_ text: String) -> QueryPlan {
        var plan = QueryPlan(engine: .mysql, rawText: text)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return plan }
        if let block = object["query_block"] as? [String: Any] {
            plan.roots = [parseBlock(block, path: "0", label: "Query Block")]
        }
        return plan
    }

    static func parseBlock(_ dict: [String: Any], path: String, label: String) -> QueryPlanNode {
        var details: [String] = []
        if let selectID = planInt(dict["select_id"]) { details.append("select_id: \(selectID)") }
        if planBool(dict["using_filesort"]) == true { details.append("using_filesort") }
        if planBool(dict["using_temporary_table"]) == true { details.append("using_temporary_table") }
        let costInfo = dict["cost_info"] as? [String: Any]
        let cost = planDouble(costInfo?["query_cost"]) ?? planDouble(costInfo?["prefix_cost"]) ?? planDouble(costInfo?["sort_cost"])

        var children: [QueryPlanNode] = []
        var index = 0
        func nextPath() -> String { let p = "\(path).\(index)"; index += 1; return p }

        if let table = dict["table"] as? [String: Any] {
            children.append(parseTable(table, path: nextPath()))
        }
        if let nestedLoop = dict["nested_loop"] as? [[String: Any]] {
            for element in nestedLoop {
                if let table = element["table"] as? [String: Any], element.count == 1 {
                    children.append(parseTable(table, path: nextPath()))
                } else {
                    children.append(parseBlock(element, path: nextPath(), label: "Nested Loop"))
                }
            }
        }
        let wrappers: [(key: String, label: String)] = [
            ("ordering_operation", "Ordering"),
            ("grouping_operation", "Grouping"),
            ("duplicates_removal", "Duplicate Removal"),
            ("buffer_result", "Buffer"),
            ("windowing_operation", "Windowing"),
            ("materialized_from_subquery", "Materialized Subquery")
        ]
        for wrapper in wrappers {
            if let child = dict[wrapper.key] as? [String: Any] {
                children.append(parseBlock(child, path: nextPath(), label: wrapper.label))
            }
        }
        if let attached = dict["attached_subqueries"] as? [[String: Any]] {
            for child in attached {
                children.append(parseBlock(child, path: nextPath(), label: "Subquery"))
            }
        }
        return QueryPlanNode(
            id: path,
            operation: label,
            estimatedTotalCost: cost,
            details: details,
            children: children
        )
    }

    static func parseTable(_ dict: [String: Any], path: String) -> QueryPlanNode {
        let accessType = planString(dict["access_type"]) ?? "table"
        let costInfo = dict["cost_info"] as? [String: Any]
        var details: [String] = ["access_type: \(accessType)"]
        if let key = planString(dict["key"]) { details.append("key: \(key)") }
        if let parts = dict["used_key_parts"] as? [String] { details.append("used_key_parts: \(parts.joined(separator: ", "))") }
        if let possible = dict["possible_keys"] as? [String] { details.append("possible_keys: \(possible.joined(separator: ", "))") }
        if let filtered = planString(dict["filtered"]) { details.append("filtered: \(filtered)%") }
        if let produced = planDouble(dict["rows_produced_per_join"]) { details.append("rows_produced_per_join: \(produced)") }
        var children: [QueryPlanNode] = []
        if let materialized = dict["materialized_from_subquery"] as? [String: Any] {
            children.append(parseBlock(materialized, path: "\(path).0", label: "Materialized Subquery"))
        }
        return QueryPlanNode(
            id: path,
            operation: accessType,
            relation: planString(dict["table_name"]),
            index: planString(dict["key"]),
            estimatedRows: planDouble(dict["rows_examined_per_scan"]),
            estimatedTotalCost: planDouble(costInfo?["prefix_cost"]),
            filter: planString(dict["attached_condition"]),
            details: details,
            children: children
        )
    }

    /// 旧版 MySQL 不支持 FORMAT=JSON 时的表格 EXPLAIN 回退：每行一个节点（扁平）。
    static func parseTabular(_ result: QueryResult) -> QueryPlan {
        var plan = QueryPlan(engine: .mysql)
        func column(_ name: String) -> Int? {
            result.columns.firstIndex { $0.lowercased() == name.lowercased() }
        }
        let typeIdx = column("type")
        let tableIdx = column("table")
        let keyIdx = column("key")
        let rowsIdx = column("rows")
        let filteredIdx = column("filtered")
        let extraIdx = column("extra")
        let selectTypeIdx = column("select_type")
        plan.roots = result.rows.enumerated().map { index, row in
            let accessType = typeIdx.flatMap { SchemaRowDecoder.string(row, at: $0) } ?? "row"
            var details: [String] = ["access_type: \(accessType)"]
            if let selectType = selectTypeIdx.flatMap({ SchemaRowDecoder.string(row, at: $0) }) {
                details.append("select_type: \(selectType)")
            }
            if let key = keyIdx.flatMap({ SchemaRowDecoder.string(row, at: $0) }) { details.append("key: \(key)") }
            if let filtered = filteredIdx.flatMap({ SchemaRowDecoder.string(row, at: $0) }) { details.append("filtered: \(filtered)%") }
            return QueryPlanNode(
                id: String(index),
                operation: accessType,
                relation: tableIdx.flatMap { SchemaRowDecoder.string(row, at: $0) },
                index: keyIdx.flatMap { SchemaRowDecoder.string(row, at: $0) },
                estimatedRows: rowsIdx.flatMap { SchemaRowDecoder.string(row, at: $0) }.flatMap(Double.init),
                filter: extraIdx.flatMap { SchemaRowDecoder.string(row, at: $0) },
                details: details
            )
        }
        return plan
    }
}

// MARK: - SQLite（EXPLAIN QUERY PLAN）

enum SQLitePlanParser {
    static func parse(_ result: QueryResult) -> QueryPlan {
        var plan = QueryPlan(engine: .sqlite)
        let columns = result.columns.map { $0.lowercased() }
        let detailIdx = columns.firstIndex(of: "detail") ?? max(0, columns.count - 1)
        let idIdx = columns.firstIndex(of: "id")
        let parentIdx = columns.firstIndex(of: "parent")

        var nodesByID: [String: QueryPlanNode] = [:]
        var order: [String] = []
        var parentOf: [String: String] = [:]
        for (index, row) in result.rows.enumerated() {
            let detail = SchemaRowDecoder.string(row, at: detailIdx) ?? ""
            let id = idIdx.flatMap { SchemaRowDecoder.string(row, at: $0) } ?? String(index)
            let extracted = parseDetail(detail)
            nodesByID[id] = QueryPlanNode(
                id: id,
                operation: detail,
                relation: extracted.relation,
                index: extracted.index,
                filter: extracted.filter,
                details: [detail]
            )
            order.append(id)
            if let parent = parentIdx.flatMap({ SchemaRowDecoder.string(row, at: $0) }) {
                parentOf[id] = parent
            }
        }

        func isRoot(_ id: String) -> Bool {
            guard let parent = parentOf[id], parent != "0" else { return true }
            return nodesByID[parent] == nil
        }

        // 先按行序收集每个父节点的子 id，再递归构建，避免值拷贝导致的深层子树丢失。
        var childrenByID: [String: [String]] = [:]
        for id in order where !isRoot(id) {
            childrenByID[parentOf[id]!, default: []].append(id)
        }
        func build(_ id: String) -> QueryPlanNode {
            var node = nodesByID[id]!
            node.children = (childrenByID[id] ?? []).map(build)
            return node
        }
        plan.roots = order.filter(isRoot).map(build)
        return plan
    }

    /// 从 detail 文本提取关系名/索引名/过滤条件，用于高亮（operation 仍保留完整 detail）。
    static func parseDetail(_ detail: String) -> (relation: String?, index: String?, filter: String?) {
        var relation: String?
        var index: String?
        var filter: String?
        let words = detail.split(separator: " ").map(String.init)
        if let first = words.first, first == "SCAN" || first == "SEARCH", words.count >= 2 {
            let candidate = words[1]
            if candidate != "CONSTANT" { relation = candidate }
        }
        if let range = detail.range(of: "USING COVERING INDEX ") {
            index = detail[range.upperBound...].split(separator: " ").first.map(String.init)
        } else if let range = detail.range(of: "USING INDEX ") {
            index = detail[range.upperBound...].split(separator: " ").first.map(String.init)
        } else if detail.contains("USING INTEGER PRIMARY KEY") {
            index = "INTEGER PRIMARY KEY"
        }
        if let open = detail.firstIndex(of: "("), let close = detail.lastIndex(of: ")"), open < close {
            filter = String(detail[open...close])
        }
        return (relation, index, filter)
    }
}