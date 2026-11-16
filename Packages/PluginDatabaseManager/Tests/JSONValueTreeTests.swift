import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P2-5 JSON 树纯函数验收：
// - 前序节点 / 路径（含特殊键括号记法）/ childCount / subtreeEnd；
// - 折叠可见行跳过子树；搜索键/路径/标量（大小写不敏感）；
// - 复制值：标量原样、容器重建语义等价；
// - CFBoolean 与数字 0/1 区分；
// - 1MB JSON 在 Task.detached 中构建（不占主线程），节点规模与搜索正确。

struct JSONValueTreeTests {
    private let sample = "{\"name\":\"x\",\"items\":[{\"id\":1},{\"id\":2}]}"

    @Test func buildsPreorderNodesWithPaths() throws {
        let nodes = try #require(JSONValueTree.build(from: sample))
        #expect(nodes.count == 7)
        #expect(nodes[0].kind == .object)
        #expect(nodes[0].childCount == 2)
        #expect(nodes[0].subtreeEnd == 7)
        #expect(nodes[1].key == "items")
        #expect(nodes[1].path == "$.items")
        #expect(nodes[1].kind == .array)
        #expect(nodes[1].childCount == 2)
        #expect(nodes[2].key == "[0]")
        #expect(nodes[2].path == "$.items[0]")
        #expect(nodes[3].path == "$.items[0].id")
        #expect(nodes[3].kind == .number)
        #expect(nodes[3].scalar == "1")
        #expect(nodes[6].key == "name")
        #expect(nodes[6].scalar == "x")
        #expect(nodes[3].parent == 2)
        #expect(nodes[2].depth == 2)
    }

    @Test func scalarRoots() throws {
        #expect(try #require(JSONValueTree.build(from: "42")).first?.kind == .number)
        #expect(try #require(JSONValueTree.build(from: "\"hi\"")).first?.scalar == "hi")
        #expect(try #require(JSONValueTree.build(from: "true")).first?.kind == .bool)
        #expect(try #require(JSONValueTree.build(from: "null")).first?.kind == .null)
    }

    @Test func invalidJSONReturnsNil() {
        #expect(JSONValueTree.build(from: "{bad") == nil)
        #expect(JSONValueTree.build(from: "") == nil)
        #expect(JSONValueTree.build(from: "   ") == nil)
    }

    @Test func boolDistinctFromZeroOne() throws {
        let nodes = try #require(JSONValueTree.build(from: "{\"a\":1,\"b\":true,\"c\":0,\"d\":false}"))
        let byKey = Dictionary(uniqueKeysWithValues: nodes.dropFirst().map { ($0.key, $0) })
        #expect(byKey["a"]?.kind == .number)
        #expect(byKey["a"]?.scalar == "1")
        #expect(byKey["b"]?.kind == .bool)
        #expect(byKey["b"]?.scalar == "true")
        #expect(byKey["c"]?.scalar == "0")
        #expect(byKey["d"]?.scalar == "false")
    }

    @Test func specialKeysUseBracketPath() throws {
        let nodes = try #require(JSONValueTree.build(from: "{\"a.b\":1,\"c'd\":2}"))
        let paths = nodes.dropFirst().map(\.path)
        #expect(paths.contains("$['a.b']"))
        #expect(paths.contains("$['c\\'d']"))
    }

    @Test func summaryTruncatesButScalarKeepsFull() throws {
        let long = String(repeating: "a", count: 100)
        let nodes = try #require(JSONValueTree.build(from: "{\"s\":\"\(long)\"}"))
        let scalarNode = try #require(nodes.first { $0.key == "s" })
        #expect(scalarNode.scalar == long)
        #expect(scalarNode.summary.count == 81)
        #expect(scalarNode.summary.hasSuffix("…"))
    }

    @Test func visibleRowsSkipCollapsedSubtrees() throws {
        let nodes = try #require(JSONValueTree.build(from: sample))
        // 仅根展开：根 + 两个顶层键（items 子树跳过）
        #expect(JSONValueTree.visibleRows(nodes, expanded: [0]) == [0, 1, 6])
        // 根 + items 展开：items 的两个元素对象出现，但它们的子键跳过
        #expect(JSONValueTree.visibleRows(nodes, expanded: [0, 1]) == [0, 1, 2, 4, 6])
        // 全展开
        let all = Set(nodes.map(\.id))
        #expect(JSONValueTree.visibleRows(nodes, expanded: all) == Array(0..<7))
    }

    @Test func searchMatchesKeyPathAndScalarCaseInsensitive() throws {
        let nodes = try #require(JSONValueTree.build(from: sample))
        #expect(JSONValueTree.search(nodes, query: "ID") == [3, 5])
        #expect(JSONValueTree.search(nodes, query: "items[1]") == [4, 5])
        #expect(JSONValueTree.search(nodes, query: "\"x\"") == [])
        #expect(JSONValueTree.search(nodes, query: "x") == [6])
        #expect(JSONValueTree.search(nodes, query: "  ") == [])
    }

    @Test func copyValueScalarIsRawText() throws {
        let nodes = try #require(JSONValueTree.build(from: sample))
        #expect(JSONValueTree.copyValue(nodes, at: 6) == "x")
        #expect(JSONValueTree.copyValue(nodes, at: 3) == "1")
        #expect(JSONValueTree.copyValue(nodes, at: 99) == nil)
    }

    @Test func copyValueContainerRebuildsSemanticallyEqualJSON() throws {
        let nodes = try #require(JSONValueTree.build(from: sample))
        let copied = try #require(JSONValueTree.copyValue(nodes, at: 1))
        let a = try #require(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [Any])
        let b = try #require(JSONSerialization.jsonObject(with: Data("[{\"id\":1},{\"id\":2}]".utf8)) as? [Any])
        #expect((a as NSArray) == (b as NSArray))
        let rootCopy = try #require(JSONValueTree.copyValue(nodes, at: 0))
        let ra = try #require(JSONSerialization.jsonObject(with: Data(rootCopy.utf8)) as? [String: Any])
        let rb = try #require(JSONSerialization.jsonObject(with: Data(sample.utf8)) as? [String: Any])
        #expect((ra as NSDictionary) == (rb as NSDictionary))
    }

    @Test func emptyContainers() throws {
        let nodes = try #require(JSONValueTree.build(from: "{\"a\":{},\"b\":[]}"))
        #expect(nodes[1].kind == .object)
        #expect(nodes[1].childCount == 0)
        #expect(nodes[2].kind == .array)
        #expect(JSONValueTree.visibleRows(nodes, expanded: [0]) == [0, 1, 2])
        #expect(JSONValueTree.copyValue(nodes, at: 1) == "{}")
        #expect(JSONValueTree.copyValue(nodes, at: 2) == "[]")
    }

    @Test(.timeLimit(.minutes(1)))
    func oneMegabyteJSONBuildsOffMainThread() async throws {
        // ~1MB：1200 条记录 × ~850 字节
        let payload = String(repeating: "data-", count: 140)
        var records: [String] = []
        for i in 0..<1200 {
            records.append("{\"id\":\(i),\"name\":\"user-\(i)\",\"payload\":\"\(payload)\",\"tags\":[1,2,3],\"active\":true}")
        }
        let text = "[" + records.joined(separator: ",") + "]"
        #expect(text.utf8.count > 900_000)

        let nodes = try #require(await Task.detached(priority: .userInitiated) {
            JSONValueTree.build(from: text)
        }.value)
        #expect(nodes[0].kind == .array)
        #expect(nodes[0].childCount == 1200)
        #expect(nodes.count > 10_000)

        let hits = JSONValueTree.search(nodes, query: "user-1199")
        #expect(hits.count == 1)
        #expect(nodes[hits[0]].path == "$[1199].name")

        // 折叠态可见行：仅根 + 1200 个元素对象
        let visible = JSONValueTree.visibleRows(nodes, expanded: [0])
        #expect(visible.count == 1201)
    }
}