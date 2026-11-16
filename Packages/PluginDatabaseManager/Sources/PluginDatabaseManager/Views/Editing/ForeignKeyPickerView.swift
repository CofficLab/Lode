import SwiftUI
import LumiUI

/// 外键引用值选择器：搜索引用表并点选一个键值写回单元格。
///
/// 搜索词防抖 200ms；候选项展示键值与至多 3 个其余列的预览。
struct ForeignKeyPickerView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    // MARK: - Properties

    let title: String
    let fetch: (String) async throws -> [FKReferenceOption]
    let onPick: (DatabaseValue) -> Void

    // MARK: - State

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var options: [FKReferenceOption] = []
    @State private var isLoading = false
    @State private var errorText: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            GlassTextField(
                title: pluginLocalization.string("Search references"),
                text: $search,
                placeholder: pluginLocalization.string("Type to search")
            )
            .padding(12)
            AppDivider()
            content
        }
        .frame(width: 440, height: 480)
        .background(theme.surface)
        .task(id: search) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primary)
            Text(title)
                .font(.appBodyEmphasized)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close"), size: .compact) {
                dismiss()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let errorText {
            AppErrorBanner(message: LocalizedStringKey(errorText))
                .padding(12)
            Spacer()
        } else if options.isEmpty {
            VStack {
                Spacer()
                AppEmptyState(icon: "link", title: pluginLocalization.string("No matching references"))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options.indices, id: \.self) { index in
                        optionRow(options[index])
                        if index < options.count - 1 {
                            AppDivider()
                        }
                    }
                }
            }
        }
    }

    private func optionRow(_ option: FKReferenceOption) -> some View {
        Button {
            onPick(option.keyValue)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(describing: option.keyValue))
                    .font(.appBodyEmphasized)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !option.preview.isEmpty {
                    Text(option.preview)
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private func load() async {
        if !search.isEmpty {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
        }
        isLoading = true
        errorText = nil
        do {
            let fetched = try await fetch(search)
            guard !Task.isCancelled else { return }
            options = fetched
        } catch {
            guard !Task.isCancelled else { return }
            options = []
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 预览

#if DEBUG
#Preview("FK Picker") {
    ForeignKeyPickerView(
        title: "parent_id → parents",
        fetch: { _ in
            [
                FKReferenceOption(keyValue: .integer(1), preview: "name: Alpha"),
                FKReferenceOption(keyValue: .integer(2), preview: "name: Beta")
            ]
        },
        onPick: { _ in }
    )
}
#endif