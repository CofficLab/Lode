import LumiUI
import SwiftUI

/// 打开值查看器的请求（sheet item）。
struct ValueViewerRequest: Identifiable {
    let id = UUID()
    let column: String
    let value: DatabaseValue
}

/// 单元格值查看器：JSON 树（折叠/搜索/复制路径/复制值）、纯文本、BLOB hex。
///
/// 大 JSON 的解析与树构建在 `Task.detached` 中完成，主线程只接收构建好的
/// 扁平节点数组；树与 hex 都用 LazyVStack 按需渲染，1MB 级值不卡主线程。
@MainActor
struct CellValueViewerSheet: View {
    let column: String
    let value: DatabaseValue

    @Environment(\.dismiss) private var dismiss
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    private enum Mode: Hashable { case json, text, hex }

    @State private var mode: Mode = .text
    @State private var nodes: [JSONTreeNode] = []
    @State private var expanded: Set<Int> = [0]
    @State private var selected: Int?
    @State private var search = ""
    @State private var isLoading = false
    @State private var jsonFailed = false

    private static let searchResultCap = 500

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            toolbar
            if mode == .json {
                GlassTextField(
                    title: pluginLocalization.string("Search keys and values"),
                    text: $search,
                    placeholder: pluginLocalization.string("Search keys and values")
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            AppDivider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            AppDivider()
            footer
        }
        .frame(width: 680, height: 560)
        .background(theme.surface)
        .task { await prepare() }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: modeIcon)
                .foregroundStyle(theme.primary)
            Text(column)
                .font(.appBodyEmphasized)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(modeLabel)
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close"), size: .compact) {
                dismiss()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var footer: some View {
        HStack {
            if jsonFailed {
                Text(pluginLocalization.string("Not valid JSON"))
                    .font(.appMicro)
                    .foregroundStyle(theme.warning)
            }
            Spacer()
            Text(sizeLabel)
                .font(.appMicro)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var modeIcon: String {
        switch mode {
        case .json: return "curlybraces"
        case .text: return "doc.text"
        case .hex: return "number"
        }
    }

    private var modeLabel: String {
        switch mode {
        case .json: return pluginLocalization.string("JSON Tree")
        case .text: return pluginLocalization.string("Plain Text")
        case .hex: return pluginLocalization.string("Hex View")
        }
    }

    private var sizeLabel: String {
        switch mode {
        case .json:
            return "\(nodes.count.formatted()) \(pluginLocalization.string("nodes"))"
        case .hex:
            return "\((blob ?? Data()).count.formatted()) \(pluginLocalization.string("bytes"))"
        case .text:
            return "\(text.count.formatted()) \(pluginLocalization.string("characters"))"
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !nodes.isEmpty {
                Picker("", selection: $mode) {
                    Text(pluginLocalization.string("JSON Tree")).tag(Mode.json)
                    Text(pluginLocalization.string("Plain Text")).tag(Mode.text)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            Spacer()
            switch mode {
            case .json:
                AppIconButton(systemImage: "chevron.down", label: pluginLocalization.string("Expand All"), size: .compact) {
                    expanded = Set(nodes.filter { $0.childCount > 0 }.map(\.id))
                }
                AppIconButton(systemImage: "chevron.up", label: pluginLocalization.string("Collapse All"), size: .compact) {
                    expanded = [0]
                }
                AppButton(pluginLocalization.string("Copy Path"), systemImage: "link", style: .ghost, size: .small) {
                    if let selected, selected < nodes.count {
                        copyToPasteboard(nodes[selected].path)
                    }
                }
                .disabled(selected == nil)
                AppButton(pluginLocalization.string("Copy Value"), systemImage: "doc.on.doc", style: .ghost, size: .small) {
                    if let selected {
                        copyToPasteboard(JSONValueTree.copyValue(nodes, at: selected))
                    }
                }
                .disabled(selected == nil)
            case .hex:
                AppButton(pluginLocalization.string("Copy Hex"), systemImage: "doc.on.doc", style: .ghost, size: .small) {
                    if let blob {
                        copyToPasteboard("0x" + HexFormatter.hexString(blob))
                    }
                }
            case .text:
                AppButton(pluginLocalization.string("Copy"), systemImage: "doc.on.doc", style: .ghost, size: .small) {
                    copyToPasteboard(text)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch mode {
            case .json: jsonContent
            case .hex: hexContent
            case .text: textContent
            }
        }
    }

    @ViewBuilder
    private var jsonContent: some View {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            let hits = Array(JSONValueTree.search(nodes, query: needle).prefix(Self.searchResultCap))
            if hits.isEmpty {
                AppEmptyState(
                    icon: "magnifyingglass",
                    title: pluginLocalization.string("No matches"),
                    description: ""
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hits, id: \.self) { id in
                            searchRow(id)
                        }
                    }
                }
            }
        } else {
            let visible = JSONValueTree.visibleRows(nodes, expanded: expanded)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible, id: \.self) { id in
                        treeRow(id)
                    }
                }
            }
        }
    }

    private func treeRow(_ id: Int) -> some View {
        let node = nodes[id]
        let isContainer = node.kind == .object || node.kind == .array
        let isExpanded = expanded.contains(id)
        return HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(node.depth) * 14)
            if isContainer {
                Button {
                    if isExpanded { expanded.remove(id) } else { expanded.insert(id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Text(node.key)
                .font(.appMicroEmphasized)
                .foregroundStyle(theme.textPrimary)
            Text(isContainer ? containerLabel(node) : node.summary)
                .font(.appMicro)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(selected == id ? theme.primary.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = id }
    }

    private func searchRow(_ id: Int) -> some View {
        let node = nodes[id]
        return VStack(alignment: .leading, spacing: 2) {
            Text(node.path)
                .font(.appMicroEmphasized)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(node.kind == .object || node.kind == .array ? containerLabel(node) : node.summary)
                .font(.appMicro)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(selected == id ? theme.primary.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = id }
    }

    private func containerLabel(_ node: JSONTreeNode) -> String {
        if node.childCount == 0 { return node.kind == .object ? "{}" : "[]" }
        let unit = node.kind == .object
            ? pluginLocalization.string("keys")
            : pluginLocalization.string("items")
        let brace = node.kind == .object ? "{…}" : "[…]"
        return "\(brace) \(node.childCount.formatted()) \(unit)"
    }

    private var hexContent: some View {
        let data = blob ?? Data()
        let count = HexFormatter.rowCount(data)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    let row = HexFormatter.row(data, at: index)
                    HStack(spacing: 12) {
                        Text(String(format: "%08x", row.offset))
                            .foregroundStyle(theme.textTertiary)
                        Text(row.hex)
                            .foregroundStyle(theme.textPrimary)
                        Text(row.ascii)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .font(.monospaced(.appMicro)())
                }
            }
            .padding(12)
        }
    }

    private var textContent: some View {
        ScrollView {
            Text(text)
                .font(.monospaced(.appCaption)())
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    // MARK: - Data

    private var blob: Data? {
        if case .data(let data) = value { return data }
        return nil
    }

    private var text: String {
        if case .string(let string) = value { return string }
        return String(describing: value)
    }

    private func prepare() async {
        if blob != nil {
            mode = .hex
            return
        }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.hasPrefix("{") || source.hasPrefix("[") else {
            mode = .text
            return
        }
        isLoading = true
        let built = await Task.detached(priority: .userInitiated) {
            JSONValueTree.build(from: source)
        }.value
        isLoading = false
        if let built, !built.isEmpty {
            nodes = built
            expanded = [0]
            mode = .json
        } else {
            jsonFailed = true
            mode = .text
        }
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}