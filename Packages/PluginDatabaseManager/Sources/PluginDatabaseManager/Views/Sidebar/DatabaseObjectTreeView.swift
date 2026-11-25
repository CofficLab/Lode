import LumiUI
import SwiftUI

/// 侧边栏对象树：按对象分类（Tables / Views / 例程）分组展示当前连接的可浏览对象。
///
/// 数据来自 ``DatabaseViewModel/schemaCache``，由 ``DatabaseViewModel/refreshSidebarObjects()``
/// 在连接成功后预加载。MySQL/PostgreSQL 由此获得与 SQLite 一致的表浏览体验。
///
/// 树结构：分类节点（可展开）→ 对象叶子节点。顶部 ``AppSearchBar`` 按名称过滤。
struct DatabaseObjectTreeView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel

    /// 点击切换数据/连接列表的回调（与既有侧边栏头部一致）。
    var onToggleMode: () -> Void

    @State private var searchText: String = ""
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            DatabaseSidebarHeaderBar(
                title: headerTitle,
                systemImage: "list.bullet.indent",
                onLoad: { Task { await viewModel.refreshSidebarObjects() } },
                onToggleMode: onToggleMode,
                toggleMode: viewModel.sidebarMode,
                menuActions: [
                    DatabaseSidebarMenuAction(
                        title: "Back to Connections",
                        systemImage: "rectangle.portrait.on.rectangle.portrait",
                        action: onToggleMode
                    ),
                ],
                accessibilityPrefix: "database.objects"
            )

            if let config = viewModel.selectedConfig, config.type == .mysql || config.type == .postgresql {
                schemaContextBar(config)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(pluginLocalization.string("Filter objects"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.appCaption)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.appSubtleBorder, in: .rect(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            if groupedNodes.isEmpty {
                SidebarEmptyView(
                    systemImage: "tablecells",
                    title: pluginLocalization.string("No objects"),
                    description: pluginLocalization.string("Click Reload to refresh the object list.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groupedNodes) { node in
                            groupRow(node)
                            if expandedGroups.contains(node.id) {
                                ForEach(node.children ?? []) { child in
                                    leafRow(child)
                                        .padding(.leading, 14)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Schema Context Bar

    /// 库/schema 切换条：MySQL/PG 显示库选择，PG 额外显示 schema 选择。
    /// 切换后对象树与查询上下文跟随 ``DatabaseViewModel/activeDatabase``/``DatabaseViewModel/activeSchema``。
    @ViewBuilder
    private func schemaContextBar(_ config: DatabaseConfig) -> some View {
        HStack(spacing: 6) {
            contextMenu(
                title: viewModel.activeDatabase ?? config.database,
                systemImage: "cylinder",
                items: viewModel.availableDatabases,
                selection: viewModel.activeDatabase ?? config.database
            ) { database in
                Task { await viewModel.switchDatabase(database) }
            }
            if config.type == .postgresql {
                contextMenu(
                    title: viewModel.activeSchema ?? "public",
                    systemImage: "square.stack.3d.down.right",
                    items: viewModel.availableSchemas,
                    selection: viewModel.activeSchema ?? "public"
                ) { schema in
                    Task { await viewModel.switchSchema(schema) }
                }
            }
            if viewModel.isLoadingSchemaContext {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// 单个上下文选择菜单：列出可选项，当前项打勾，点击触发切换。
    @ViewBuilder
    private func contextMenu(
        title: String,
        systemImage: String,
        items: [String],
        selection: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            if items.isEmpty {
                Text(pluginLocalization.string("None available"))
            } else {
                ForEach(items, id: \.self) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        if item == selection {
                            Label(item, systemImage: "checkmark")
                        } else {
                            Text(item)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(title)
                    .font(.appCaption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.appSubtleBorder, in: .rect(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Derived

    private var headerTitle: String {
        viewModel.selectedConfig?.name ?? pluginLocalization.string("Database")
    }

    /// 当前选中对象名，用于高亮行。
    private var selectedObjectName: String? {
        viewModel.selectedSQLiteTable
    }

    /// 按对象分类分组成树节点，应用搜索过滤；空分类隐藏。
    private var groupedNodes: [TreeNode] {
        guard let config = viewModel.selectedConfig else { return [] }
        let predicate = makeSearchPredicate()
        var nodes: [TreeNode] = []
        for kind in config.type.sidebarObjectKinds {
            let key = SchemaCacheService.CacheKey(
                configId: config.id,
                kind: kind,
                database: config.type == .sqlite ? nil : (viewModel.activeDatabase ?? config.database),
                schema: config.type == .postgresql ? viewModel.activeSchema : nil
            )
            let objects = (viewModel.schemaCache.objectsByKey[key] ?? []).filter(predicate)
            if objects.isEmpty { continue }
            let children = objects.map { object in
                TreeNode(
                    id: object.id,
                    kind: kind,
                    object: object,
                    title: object.name,
                    systemImage: kind.systemImage,
                    children: nil
                )
            }
            nodes.append(TreeNode(
                id: "kind-\(kind.rawValue)",
                kind: kind,
                object: nil,
                title: "\(pluginLocalization.string(kind.sectionKey)) (\(objects.count))",
                systemImage: "folder",
                children: children
            ))
        }
        return nodes
    }

    private func makeSearchPredicate() -> (DatabaseObject) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return { _ in true } }
        return { $0.name.lowercased().contains(trimmed) }
    }

    // MARK: - Rows

    @ViewBuilder
    private func groupRow(_ node: TreeNode) -> some View {
        let isExpanded = expandedGroups.contains(node.id)
        Button {
            if isExpanded {
                expandedGroups.remove(node.id)
            } else {
                expandedGroups.insert(node.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                Image(systemName: node.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(node.title)
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("database.objects.group.\(node.kind?.rawValue ?? node.id)")
        .accessibilityLabel(node.title)
    }

    @ViewBuilder
    private func leafRow(_ node: TreeNode) -> some View {
        let isSelected = selectedObjectName == node.object?.name
        AppSidebarRow(
            title: node.title,
            systemImage: node.systemImage,
            leadingColor: nil,
            isSelected: isSelected
        ) {
            guard let object = node.object else { return }
            Task { await viewModel.openObject(object) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("database.objects.row.\(node.title)")
        .contextMenu {
            if let object = node.object {
                Button {
                    Task { await viewModel.openObject(object) }
                } label: {
                    Label(pluginLocalization.string("Open"), systemImage: "arrow.right.circle")
                }
            }
        }
    }
}

// MARK: - Tree node model

private struct TreeNode: Identifiable, Hashable {
    let id: String
    let kind: DatabaseObjectKind?
    let object: DatabaseObject?
    let title: String
    let systemImage: String
    let children: [TreeNode]?
}
