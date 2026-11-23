import AppKit
import LumiUI
import SwiftUI
import UniformTypeIdentifiers

/// 只读 ER 图面板：Canvas 渲染当前库/schema 的表关系图，支持缩放/平移与 PNG/SVG/Mermaid 导出。
struct ERDiagramView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool

    @State private var zoom: CGFloat = 1.0
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            content
        }
        .frame(width: 860, height: 620)
        .background(theme.surface)
        .task { await viewModel.loadERDiagram() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(pluginLocalization.string("ER Diagram"))
                .font(.appTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if viewModel.erDiagram?.nodes.isEmpty == false {
                HStack(spacing: 4) {
                    AppIconButton(systemImage: "minus.magnifyingglass", label: pluginLocalization.string("Zoom Out"), size: .compact) {
                        zoom = max(0.4, zoom - 0.2)
                    }
                    Text("\(Int(zoom * 100))%")
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44)
                    AppIconButton(systemImage: "plus.magnifyingglass", label: pluginLocalization.string("Zoom In"), size: .compact) {
                        zoom = min(2.5, zoom + 0.2)
                    }
                }
                exportMenu
                AppIconButton(systemImage: "arrow.clockwise", label: pluginLocalization.string("Reload"), size: .compact) {
                    Task { await viewModel.loadERDiagram(refresh: true) }
                }
            }
            AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close"), size: .compact) {
                isPresented = false
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var exportMenu: some View {
        Menu {
            Button(pluginLocalization.string("Export PNG")) { exportPNG() }
            Button(pluginLocalization.string("Export SVG")) { exportText(viewModel.erDiagram?.svgRepresentation(), ext: "svg") }
            Button(pluginLocalization.string("Export Mermaid")) { exportText(viewModel.erDiagram?.mermaidRepresentation(), ext: "mmd") }
        } label: {
            Label(pluginLocalization.string("Export"), systemImage: "square.and.arrow.up")
                .font(.appCaption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let exportError {
            AppErrorBanner(message: LocalizedStringKey(exportError))
                .padding(16)
        }
        if viewModel.isLoadingERDiagram && viewModel.erDiagram == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.erDiagramError {
            VStack(spacing: 12) {
                AppErrorBanner(message: LocalizedStringKey(error))
                AppButton(pluginLocalization.string("Retry"), style: .secondary) {
                    Task { await viewModel.loadERDiagram(refresh: true) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diagram = viewModel.erDiagram, !diagram.nodes.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                makeCanvas(diagram: diagram, zoom: zoom)
                    .padding(8)
            }
            .background(theme.surface)
        } else {
            AppEmptyState(
                icon: "rectangle.3.group",
                title: pluginLocalization.string("No tables to diagram"),
                description: pluginLocalization.string("Connect to a database with tables to see their relationships.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func makeCanvas(diagram: ERDiagram, zoom: CGFloat) -> ERCanvas {
        ERCanvas(
            diagram: diagram,
            zoom: zoom,
            background: theme.surface,
            nodeFill: theme.surface,
            headerFill: theme.primary.opacity(0.10),
            border: theme.appSubtleBorder,
            textPrimary: theme.textPrimary,
            textSecondary: theme.textSecondary,
            edge: theme.textTertiary,
            accent: theme.primary
        )
    }

    // MARK: - Export

    private func exportPNG() {
        guard let diagram = viewModel.erDiagram else { return }
        let renderer = ImageRenderer(content: makeCanvas(diagram: diagram, zoom: 1))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            exportError = pluginLocalization.string("Could not render the diagram image.")
            return
        }
        save(data: png, ext: "png")
    }

    private func exportText(_ text: String?, ext: String) {
        guard let text else { return }
        save(data: Data(text.utf8), ext: ext)
    }

    private func save(data: Data, ext: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "er-diagram.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// ER 图的 Canvas 绘制。同一视图既用于屏幕显示，也用于 ImageRenderer 导出 PNG。
struct ERCanvas: View {
    let diagram: ERDiagram
    let zoom: CGFloat
    let background: Color
    let nodeFill: Color
    let headerFill: Color
    let border: Color
    let textPrimary: Color
    let textSecondary: Color
    let edge: Color
    let accent: Color

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: zoom, y: zoom)
            context.fill(
                Path(CGRect(origin: .zero, size: diagram.canvasSize)),
                with: .color(background)
            )

            for relation in diagram.edges {
                guard let from = diagram.node(id: relation.fromNode),
                      let to = diagram.node(id: relation.toNode) else { continue }
                let fromHeight = ERLayout.nodeHeight(from)
                let toHeight = ERLayout.nodeHeight(to)
                let start = CGPoint(x: from.position.x, y: from.position.y + fromHeight / 2)
                let end = CGPoint(x: to.position.x + ERLayout.nodeWidth, y: to.position.y + toHeight / 2)
                let midX = (start.x + end.x) / 2
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
                context.stroke(path, with: .color(edge), lineWidth: 1.5)
                if !relation.name.isEmpty {
                    context.draw(
                        Text(relation.name).font(.appMicro).foregroundColor(edge),
                        at: CGPoint(x: midX, y: (start.y + end.y) / 2 - 6),
                        anchor: .center
                    )
                }
            }

            for node in diagram.nodes {
                let rect = CGRect(
                    x: node.position.x, y: node.position.y,
                    width: ERLayout.nodeWidth, height: ERLayout.nodeHeight(node)
                )
                let bodyPath = Path(roundedRect: rect, cornerRadius: 6)
                context.fill(bodyPath, with: .color(nodeFill))
                context.stroke(bodyPath, with: .color(border), lineWidth: 1)
                let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ERLayout.headerHeight)
                context.fill(Path(roundedRect: headerRect, cornerRadius: 6), with: .color(headerFill))
                context.draw(
                    Text(node.name).font(.appCaptionEmphasized).foregroundColor(textPrimary),
                    at: CGPoint(x: rect.minX + 10, y: rect.minY + 15),
                    anchor: .leading
                )
                var cursorY = rect.minY + ERLayout.headerHeight + 13
                for column in node.columns {
                    let marker = column.isPrimaryKey ? "PK " : (column.isForeignKey ? "FK " : "")
                    let color = (column.isPrimaryKey || column.isForeignKey) ? accent : textSecondary
                    context.draw(
                        Text("\(marker)\(column.name) : \(column.dataType)")
                            .font(.appMonoMicro)
                            .foregroundColor(color),
                        at: CGPoint(x: rect.minX + 10, y: cursorY),
                        anchor: .leading
                    )
                    cursorY += ERLayout.rowHeight
                }
            }
        }
        .frame(width: diagram.canvasSize.width * zoom, height: diagram.canvasSize.height * zoom)
    }
}