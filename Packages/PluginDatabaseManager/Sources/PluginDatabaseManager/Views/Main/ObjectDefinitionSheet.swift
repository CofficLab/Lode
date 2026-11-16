import SwiftUI
import LumiUI
import ProviderEditor

/// 对象定义面板：展示索引/触发器/例程的 DDL，支持复制；例程与触发器（MySQL/PG）可编辑源码并经写闸门保存。
/// DDL 缺失（引擎 introspection 尚未覆盖）时展示空态。
struct ObjectDefinitionSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel
    let definition: DatabaseViewModel.ObjectDefinitionDisplay
    let onClose: () -> Void

    private var live: DatabaseViewModel.ObjectDefinitionDisplay { viewModel.objectDefinition ?? definition }
    private var isEditing: Bool { viewModel.objectDefinitionDraft != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            content
            if let error = viewModel.definitionSaveError {
                AppErrorBanner(message: LocalizedStringKey(error))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            AppDivider()
            footer
        }
        .frame(width: 680, height: 520)
        .appSurface(style: .toolbar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: live.object.kind.systemImage)
                .foregroundStyle(theme.primary)
            Text(live.object.name)
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
            AppTag(live.object.kind.rawValue)
            if isEditing {
                AppTag(pluginLocalization.string("Editing"), style: .subtle)
            }
            Spacer()
            if !isEditing {
                AppButton(pluginLocalization.string("Close"), style: .ghost, size: .small, action: onClose)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        if live.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = live.errorMessage {
            AppErrorBanner(message: LocalizedStringKey(errorMessage))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                Label(pluginLocalization.string("Saving replaces this object. Review the source before applying."), systemImage: "exclamationmark.triangle")
                    .font(.appCaption)
                    .foregroundStyle(theme.warning)
                EmbeddedCodeEditorView(
                    text: draftBinding,
                    options: EditorEmbeddedEditorOptions(
                        languageID: "sql",
                        isEditable: true,
                        wrapLines: false,
                        fontSize: NSFont.smallSystemFontSize
                    ),
                    provider: viewModel.embeddedEditorProvider
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(12)
        } else if let ddl = live.ddl, !ddl.isEmpty {
            ScrollView {
                Text(ddl)
                    .font(.monospaced(.callout)())
                    .foregroundColor(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else {
            AppEmptyState(
                icon: live.object.kind.systemImage,
                title: pluginLocalization.string("Definition not available"),
                description: pluginLocalization.string("This engine does not expose the definition of this object yet.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isEditing {
            HStack {
                if viewModel.isSavingDefinition {
                    ProgressView().controlSize(.small)
                    Text(pluginLocalization.string("Saving…"))
                        .font(.appCaption).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                AppButton(pluginLocalization.string("Cancel"), style: .secondary, size: .small) {
                    viewModel.cancelEditDefinition()
                }
                AppButton(pluginLocalization.string("Save Definition"), systemImage: "checkmark", style: .primary, size: .small) {
                    Task { await viewModel.saveDefinition() }
                }
                .disabled(viewModel.isSavingDefinition || (viewModel.objectDefinitionDraft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        } else {
            HStack {
                Spacer()
                AppButton(pluginLocalization.string("Copy"), systemImage: "doc.on.doc", style: .secondary, size: .small) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(live.ddl ?? "", forType: .string)
                }
                .disabled(live.ddl == nil || live.ddl?.isEmpty == true)
                if viewModel.canEditDefinition {
                    AppButton(pluginLocalization.string("Edit"), systemImage: "pencil", style: .primary, size: .small) {
                        viewModel.beginEditDefinition()
                    }
                    .disabled(live.ddl == nil || live.ddl?.isEmpty == true)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { viewModel.objectDefinitionDraft ?? "" },
            set: { viewModel.objectDefinitionDraft = $0 }
        )
    }
}