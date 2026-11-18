import SwiftUI
import LumiUI

/// 侧边栏「收藏查询 / 片段」分区：嵌在对象树底部，可折叠。
///
/// 收藏查询按当前连接组织（``DatabaseViewModel/currentConnectionSavedQueries``），
/// 点击载入编辑器，右键重执行/重命名/删除；顶部「+」把当前编辑器文本收藏为命名查询。
/// 片段全局共享，点击在光标处展开占位符插入编辑器，右键插入/删除，「+」新建片段。
struct SavedQueriesSectionView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel

    @State private var isExpanded = false
    @State private var showSaveAlert = false
    @State private var saveName = ""
    @State private var showRenameAlert = false
    @State private var renameTarget: SavedQuery?
    @State private var renameText = ""
    @State private var showSnippetSheet = false
    @State private var snippetName = ""
    @State private var snippetBody = ""

    var body: some View {
        VStack(spacing: 0) {
            AppDivider()
            headerRow
            if isExpanded {
                expandedContent
                    .frame(maxHeight: 220)
            }
        }
        .alert(pluginLocalization.string("Save Query"), isPresented: $showSaveAlert) {
            TextField(pluginLocalization.string("Name"), text: $saveName)
            Button(pluginLocalization.string("Save")) {
                viewModel.saveCurrentQuery(name: saveName)
            }
            Button(pluginLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(pluginLocalization.string("Save the current editor text as a named query for this connection."))
        }
        .alert(pluginLocalization.string("Rename Query"), isPresented: $showRenameAlert) {
            TextField(pluginLocalization.string("Name"), text: $renameText)
            Button(pluginLocalization.string("Save")) {
                if let query = renameTarget {
                    viewModel.renameSavedQuery(id: query.id, name: renameText)
                }
            }
            Button(pluginLocalization.string("Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showSnippetSheet) {
            snippetEditor
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(theme.textTertiary)
                    Image(systemName: "bookmark")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                    Text(pluginLocalization.string("Saved Queries"))
                        .font(.appMicroEmphasized)
                        .foregroundStyle(theme.textSecondary)
                    Text("(\(viewModel.currentConnectionSavedQueries.count))")
                        .font(.appMicro)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            AppIconButton(systemImage: "plus", label: pluginLocalization.string("Save Current Query"), size: .compact) {
                saveName = ""
                showSaveAlert = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let queries = viewModel.currentConnectionSavedQueries
                if queries.isEmpty {
                    Text(pluginLocalization.string("No saved queries yet."))
                        .font(.appMicro)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ForEach(queries) { query in
                        savedQueryRow(query)
                    }
                }

                AppDivider()
                    .padding(.vertical, 4)

                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                    Text(pluginLocalization.string("Snippets"))
                        .font(.appMicroEmphasized)
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 0)
                    AppIconButton(systemImage: "plus", label: pluginLocalization.string("New Snippet"), size: .compact) {
                        snippetName = ""
                        snippetBody = ""
                        showSnippetSheet = true
                    }
                }
                .padding(.horizontal, 8)

                if viewModel.snippets.isEmpty {
                    Text(pluginLocalization.string("No snippets yet."))
                        .font(.appMicro)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ForEach(viewModel.snippets) { snippet in
                        snippetRow(snippet)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Rows

    private func savedQueryRow(_ query: SavedQuery) -> some View {
        Button {
            viewModel.loadSavedQuery(query)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(query.name)
                    .font(.appCaption)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(query.sql)
                    .font(.monospaced(.caption2)())
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await viewModel.runSavedQuery(query) }
            } label: {
                Label(pluginLocalization.string("Re-run"), systemImage: "play.fill")
            }
            Button(pluginLocalization.string("Load into Editor")) {
                viewModel.loadSavedQuery(query)
            }
            Button {
                renameTarget = query
                renameText = query.name
                showRenameAlert = true
            } label: {
                Label(pluginLocalization.string("Rename"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                viewModel.deleteSavedQuery(query)
            } label: {
                Label(pluginLocalization.string("Delete"), systemImage: "trash")
            }
        }
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        Button {
            viewModel.insertSnippet(snippet)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
                Text(snippet.name)
                    .font(.appCaption)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(pluginLocalization.string("Insert")) {
                viewModel.insertSnippet(snippet)
            }
            Button(role: .destructive) {
                viewModel.deleteSnippet(snippet)
            } label: {
                Label(pluginLocalization.string("Delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Snippet Editor

    private var snippetEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pluginLocalization.string("New Snippet"))
                .font(.appTitle)
                .foregroundStyle(theme.textPrimary)
            GlassTextField(
                title: pluginLocalization.string("Name"),
                text: $snippetName,
                placeholder: pluginLocalization.string("e.g. select")
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(pluginLocalization.string("Body"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
                TextEditor(text: $snippetBody)
                    .font(.monospaced(.callout)())
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.appSubtleBorder))
                Text(pluginLocalization.string("Use ${name} or ${name:default} for placeholders."))
                    .font(.appMicro)
                    .foregroundStyle(theme.textTertiary)
            }
            HStack {
                Spacer()
                AppButton(pluginLocalization.string("Cancel"), style: .ghost, size: .small) {
                    showSnippetSheet = false
                }
                AppButton(pluginLocalization.string("Save"), style: .primary, size: .small) {
                    viewModel.addSnippet(name: snippetName, body: snippetBody)
                    showSnippetSheet = false
                }
                .disabled(
                    snippetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || snippetBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}