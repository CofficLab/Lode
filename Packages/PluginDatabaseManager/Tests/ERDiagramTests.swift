import CoreGraphics
import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-1 ER 图：构建（FK→边）/确定性布局/导出的离线单测。

private func makeTable(
    _ name: String,
    schema: String? = nil,
    columns: [(name: String, type: String, pk: Bool)] = [],
    foreignKeys: [ForeignKey] = [],
    rowCount: Int? = nil
) -> TableSchema {
    let object = DatabaseObject(kind: .table, name: name, schema: schema, rowCount: rowCount)
    let cols = columns.enumerated().map { index, column in
        TableColumn(
            name: column.name,
            dataType: column.type,
            isNullable: !column.pk,
            isPrimaryKey: column.pk,
            defaultValue: nil,
            position: index
        )
    }
    return TableSchema(table: object, columns: cols, foreignKeys: foreignKeys)
}

@Suite(.serialized)
struct ERDiagramBuilderTests {
    @Test func buildsNodesAndEdgesFromForeignKeys() throws {
        let parent = makeTable("parent", columns: [("id", "integer", true)])
        let child = makeTable(
            "child",
            columns: [("id", "integer", true), ("parent_id", "integer", false)],
            foreignKeys: [ForeignKey(name: "fk_child_parent", columns: ["parent_id"], referencesTable: "parent", referencesColumns: ["id"], onDelete: "CASCADE")]
        )
        let diagram = ERDiagramBuilder.build(from: [child, parent])
        #expect(diagram.nodes.count == 2)
        #expect(diagram.edges.count == 1)
        let edge = try #require(diagram.edges.first)
        #expect(edge.fromNode == "child")
        #expect(edge.toNode == "parent")
        #expect(edge.fromColumns == ["parent_id"])
        #expect(edge.toColumns == ["id"])
        #expect(edge.name == "fk_child_parent")
        #expect(edge.onDelete == "CASCADE")
        let childNode = try #require(diagram.node(id: "child"))
        #expect(childNode.columns.first { $0.name == "parent_id" }?.isForeignKey == true)
        #expect(childNode.columns.first { $0.name == "id" }?.isPrimaryKey == true)
        #expect(childNode.columns.first { $0.name == "id" }?.isForeignKey == false)
    }

    @Test func addsStubNodeForUndescribedReferencedTable() throws {
        let child = makeTable(
            "child",
            columns: [("parent_id", "integer", false)],
            foreignKeys: [ForeignKey(name: "fk", columns: ["parent_id"], referencesTable: "parent", referencesColumns: ["id"])]
        )
        let diagram = ERDiagramBuilder.build(from: [child])
        #expect(diagram.nodes.count == 2)
        let stub = try #require(diagram.node(id: "parent"))
        #expect(stub.columns.isEmpty)
        #expect(diagram.edges.first?.toNode == "parent")
    }

    @Test func handlesSelfReference() throws {
        let node = makeTable(
            "node",
            columns: [("id", "integer", true), ("parent_id", "integer", false)],
            foreignKeys: [ForeignKey(name: "fk_self", columns: ["parent_id"], referencesTable: "node", referencesColumns: ["id"])]
        )
        let diagram = ERDiagramBuilder.build(from: [node])
        #expect(diagram.nodes.count == 1)
        let edge = try #require(diagram.edges.first)
        #expect(edge.fromNode == "node")
        #expect(edge.toNode == "node")
    }

    @Test func compositeForeignKeyIsSingleEdge() throws {
        let child = makeTable(
            "child",
            columns: [("a", "integer", false), ("b", "integer", false)],
            foreignKeys: [ForeignKey(name: "fk_compound", columns: ["a", "b"], referencesTable: "parent", referencesColumns: ["x", "y"])]
        )
        let diagram = ERDiagramBuilder.build(from: [child])
        #expect(diagram.edges.count == 1)
        #expect(diagram.edges.first?.fromColumns == ["a", "b"])
        #expect(diagram.edges.first?.toColumns == ["x", "y"])
    }

    @Test func schemaQualifiedNodeIDs() throws {
        let table = makeTable("users", schema: "app", columns: [("id", "integer", true)])
        let diagram = ERDiagramBuilder.build(from: [table])
        #expect(diagram.node(id: "app.users") != nil)
        #expect(diagram.nodes.first?.schema == "app")
    }

    @Test func emptyInputProducesEmptyDiagram() {
        let diagram = ERDiagramBuilder.build(from: [])
        #expect(diagram.nodes.isEmpty)
        #expect(diagram.edges.isEmpty)
        #expect(diagram.canvasSize == .zero)
    }
}

@Suite(.serialized)
struct ERDiagramLayoutTests {
    private func chain() -> [TableSchema] {
        let c = makeTable("c", columns: [("id", "integer", true)])
        let b = makeTable("b", columns: [("id", "integer", true), ("c_id", "integer", false)],
                          foreignKeys: [ForeignKey(name: "fk_b_c", columns: ["c_id"], referencesTable: "c", referencesColumns: ["id"])])
        let a = makeTable("a", columns: [("id", "integer", true), ("b_id", "integer", false)],
                          foreignKeys: [ForeignKey(name: "fk_a_b", columns: ["b_id"], referencesTable: "b", referencesColumns: ["id"])])
        return [a, b, c]
    }

    @Test func layoutIsDeterministicRegardlessOfInputOrder() throws {
        let forward = ERDiagramBuilder.build(from: chain())
        let reversed = ERDiagramBuilder.build(from: chain().reversed())
        #expect(forward.nodes.map(\.id) == reversed.nodes.map(\.id))
        #expect(forward.nodes.map(\.position) == reversed.nodes.map(\.position))
        #expect(forward.edges.map(\.id) == reversed.edges.map(\.id))
        #expect(forward.canvasSize == reversed.canvasSize)
    }

    @Test func chainLayersOrderByReferenceDepth() throws {
        let diagram = ERDiagramBuilder.build(from: chain())
        let a = try #require(diagram.node(id: "a"))
        let b = try #require(diagram.node(id: "b"))
        let c = try #require(diagram.node(id: "c"))
        // a 引用 b 引用 c：a 层最深，x 最大；c 层 0，x 最小。
        #expect(a.position.x > b.position.x)
        #expect(b.position.x > c.position.x)
        #expect(diagram.canvasSize.width > 0)
        #expect(diagram.canvasSize.height > 0)
    }

    @Test func nodesFitWithinCanvas() throws {
        let diagram = ERDiagramBuilder.build(from: chain())
        for node in diagram.nodes {
            #expect(node.position.x >= 0)
            #expect(node.position.y >= 0)
            #expect(node.position.x + ERLayout.nodeWidth <= diagram.canvasSize.width)
            #expect(node.position.y + ERLayout.nodeHeight(node) <= diagram.canvasSize.height)
        }
    }

    @Test func cyclicReferencesDoNotHangAndStayDeterministic() throws {
        let x = makeTable("x", columns: [("y_id", "integer", false)],
                          foreignKeys: [ForeignKey(name: "fk_x_y", columns: ["y_id"], referencesTable: "y", referencesColumns: ["id"])])
        let y = makeTable("y", columns: [("x_id", "integer", false)],
                          foreignKeys: [ForeignKey(name: "fk_y_x", columns: ["x_id"], referencesTable: "x", referencesColumns: ["id"])])
        let first = ERDiagramBuilder.build(from: [x, y])
        let second = ERDiagramBuilder.build(from: [y, x])
        #expect(first.nodes.count == 2)
        #expect(first.nodes.map(\.position) == second.nodes.map(\.position))
    }
}

@Suite(.serialized)
struct ERDiagramExportTests {
    private func sample() -> ERDiagram {
        let parent = makeTable("parent", columns: [("id", "integer", true)])
        let child = makeTable(
            "child",
            columns: [("id", "integer", true), ("parent_id", "integer", false)],
            foreignKeys: [ForeignKey(name: "fk_child_parent", columns: ["parent_id"], referencesTable: "parent", referencesColumns: ["id"])]
        )
        return ERDiagramBuilder.build(from: [child, parent])
    }

    @Test func mermaidContainsEntitiesAttributesAndRelationship() throws {
        let mermaid = sample().mermaidRepresentation()
        #expect(mermaid.hasPrefix("erDiagram"))
        #expect(mermaid.contains("child {"))
        #expect(mermaid.contains("parent {"))
        #expect(mermaid.contains("integer id PK"))
        #expect(mermaid.contains("integer parent_id FK"))
        #expect(mermaid.contains("child }o--|| parent : \"fk_child_parent\""))
    }

    @Test func mermaidSanitizesIdentifiers() throws {
        let table = makeTable("order items", columns: [("full name", "character varying", false)])
        let mermaid = ERDiagramBuilder.build(from: [table]).mermaidRepresentation()
        #expect(mermaid.contains("order_items {"))
        #expect(mermaid.contains("character_varying full_name"))
        #expect(!mermaid.contains("order items"))
    }

    @Test func mermaidLabelEscapesQuotes() {
        #expect(ERDiagram.mermaidLabel("a\"b") == "a'b")
        #expect(ERDiagram.mermaidLabel("a\\b") == "a\\\\b")
    }

    @Test func svgContainsStructureAndNames() throws {
        let svg = sample().svgRepresentation()
        #expect(svg.contains("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(svg.contains("<rect"))
        #expect(svg.contains("<path"))
        #expect(svg.contains(">child</text>"))
        #expect(svg.contains(">parent</text>"))
        #expect(svg.contains("</svg>"))
    }

    @Test func svgEscapesSpecialCharacters() throws {
        let table = makeTable("a<b>&\"c", columns: [("id", "integer", true)])
        let svg = ERDiagramBuilder.build(from: [table]).svgRepresentation()
        #expect(svg.contains("a&lt;b&gt;&amp;&quot;c"))
        #expect(!svg.contains("a<b>"))
    }

    @Test func xmlEscapeOrder() {
        #expect(ERDiagram.xmlEscape("&<>\"'") == "&amp;&lt;&gt;&quot;&apos;")
    }

    @Test func emptyDiagramExportsMinimalDocuments() {
        let diagram = ERDiagramBuilder.build(from: [])
        #expect(diagram.mermaidRepresentation() == "erDiagram\n")
        #expect(diagram.svgRepresentation().contains("</svg>"))
    }
}