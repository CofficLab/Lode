import SwiftUI
import LumiUI

/// 只读对象定义面板：展示索引/触发器/例程的 DDL，支持复制。
/// DDL 缺失（引擎 introspection 尚未覆盖）时展示空态。
struct ObjectDefinitionSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    let definition: DatabaseViewModel.ObjectDefinitionDisplay
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            content
            AppDivider()
            footer
        }
        .frame(width: 620, height: 480)
        .appSurface(style: .toolbar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: definition.object.kind.systemImage)
                .foregroundStyle(.secondary)
            Text(definition.object.name)
                .font(.appBodyEmphasized)
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
            AppTag(definition.object.kind.rawValue)
            Spacer()
            AppButton(pluginLocalization.string("Close"), style: .ghost, size: .small, action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        if definition.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = definition.errorMessage {
            AppErrorBanner(message: LocalizedStringKey(errorMessage))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let ddl = definition.ddl, !ddl.isEmpty {
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
                icon: definition.object.kind.systemImage,
                title: pluginLocalization.string("Definition not available"),
                description: pluginLocalization.string("This engine does not expose the definition of this object yet.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            AppButton(pluginLocalization.string("Copy"), systemImage: "doc.on.doc", style: .secondary, size: .small) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(definition.ddl ?? "", forType: .string)
            }
            .disabled(definition.ddl == nil || definition.ddl?.isEmpty == true)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}