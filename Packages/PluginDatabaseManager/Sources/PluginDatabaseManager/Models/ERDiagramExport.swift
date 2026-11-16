import Foundation

/// ER 图的文本导出：Mermaid erDiagram 与 SVG。均为纯函数，离线可测。
/// PNG 由 UI 层用 ImageRenderer 渲染同一 Canvas 视图得到（见 ERDiagramView）。
extension ERDiagram {
    // MARK: - Mermaid

    func mermaidRepresentation() -> String {
        var lines = ["erDiagram"]
        for node in nodes {
            let entity = Self.mermaidIdentifier(node.name)
            if node.columns.isEmpty {
                lines.append("    \(entity)")
                continue
            }
            lines.append("    \(entity) {")
            for column in node.columns {
                var attribute = "\(Self.mermaidIdentifier(column.dataType)) \(Self.mermaidIdentifier(column.name))"
                var keys: [String] = []
                if column.isPrimaryKey { keys.append("PK") }
                if column.isForeignKey { keys.append("FK") }
                if !keys.isEmpty { attribute += " " + keys.joined(separator: ",") }
                lines.append("        \(attribute)")
            }
            lines.append("    }")
        }
        for edge in edges {
            let from = Self.mermaidIdentifier(node(id: edge.fromNode)?.name ?? edge.fromNode)
            let to = Self.mermaidIdentifier(node(id: edge.toNode)?.name ?? edge.toNode)
            let label = edge.name.isEmpty ? "references" : edge.name
            lines.append("    \(from) }o--|| \(to) : \"\(Self.mermaidLabel(label))\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Mermaid 实体/属性标识符：仅保留字母数字下划线，数字开头补前缀。
    static func mermaidIdentifier(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        var result = String(scalars)
        if result.isEmpty { result = "entity" }
        if let first = result.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            result = "_" + result
        }
        return result
    }

    /// Mermaid 关系标签（双引号内）：转义引号与反斜杠。
    static func mermaidLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
    }

    // MARK: - SVG

    func svgRepresentation() -> String {
        let width = Int(canvasSize.width.rounded(.up))
        let height = Int(canvasSize.height.rounded(.up))
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">\n"
        svg += "<rect width=\"\(width)\" height=\"\(height)\" fill=\"#FFFFFF\"/>\n"

        // 边先画，落在节点下方。
        for edge in edges {
            guard let from = node(id: edge.fromNode), let to = node(id: edge.toNode) else { continue }
            let fromHeight = ERLayout.nodeHeight(from)
            let toHeight = ERLayout.nodeHeight(to)
            let x1 = from.position.x
            let y1 = from.position.y + fromHeight / 2
            let x2 = to.position.x + ERLayout.nodeWidth
            let y2 = to.position.y + toHeight / 2
            let midX = (x1 + x2) / 2
            svg += "<path d=\"M \(x1) \(y1) C \(midX) \(y1), \(midX) \(y2), \(x2) \(y2)\" fill=\"none\" stroke=\"#8A8A8A\" stroke-width=\"1.5\"/>\n"
            if !edge.name.isEmpty {
                svg += "<text x=\"\(midX)\" y=\"\((y1 + y2) / 2 - 4)\" font-family=\"monospace\" font-size=\"10\" fill=\"#6A6A6A\" text-anchor=\"middle\">\(Self.xmlEscape(edge.name))</text>\n"
            }
        }

        for node in nodes {
            let x = node.position.x
            let y = node.position.y
            let nodeHeight = ERLayout.nodeHeight(node)
            svg += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(ERLayout.nodeWidth)\" height=\"\(nodeHeight)\" rx=\"6\" fill=\"#FFFFFF\" stroke=\"#C9C9C9\"/>\n"
            svg += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(ERLayout.nodeWidth)\" height=\"\(ERLayout.headerHeight)\" rx=\"6\" fill=\"#F0F0F0\" stroke=\"#C9C9C9\"/>\n"
            svg += "<text x=\"\(x + 10)\" y=\"\(y + 20)\" font-family=\"sans-serif\" font-size=\"13\" font-weight=\"bold\" fill=\"#1A1A1A\">\(Self.xmlEscape(node.name))</text>\n"
            var cursorY = y + ERLayout.headerHeight + 14
            for column in node.columns {
                let marker = column.isPrimaryKey ? "PK " : (column.isForeignKey ? "FK " : "")
                let label = "\(marker)\(column.name) : \(column.dataType)"
                svg += "<text x=\"\(x + 10)\" y=\"\(cursorY)\" font-family=\"monospace\" font-size=\"11\" fill=\"#3A3A3A\">\(Self.xmlEscape(label))</text>\n"
                cursorY += ERLayout.rowHeight
            }
        }

        svg += "</svg>\n"
        return svg
    }

    static func xmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}