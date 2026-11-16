import LumiUI
import SwiftUI

/// 提交前乐观锁冲突解决面板：列出被他人改动的行，提供「覆盖 / 放弃冲突行 / 取消」，
/// 并按列展示 原始值 → 当前值 → 你的修改 的差异。
struct ConflictResolutionSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    let conflicts: [RowConflict]
    @Binding var isPresented: Bool
    var onOverwrite: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(pluginLocalization.string("These rows were changed by another client after you started editing. Choose how to proceed."))
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(conflicts) { conflict in
                        conflictCard(conflict)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .padding()
        .frame(width: 640, height: 500)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
            Text(pluginLocalization.string("Resolve Conflicts"))
                .font(.appTitle)
                .foregroundColor(theme.textPrimary)
            AppTag("\(conflicts.count)", style: .subtle)
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            AppButton(pluginLocalization.string("Cancel"), style: .ghost, size: .small) {
                isPresented = false
                onCancel()
            }
            Spacer()
            AppButton(
                pluginLocalization.string("Discard Conflicted Rows"),
                systemImage: "trash",
                style: .secondary,
                size: .small
            ) {
                isPresented = false
                onDiscard()
            }
            AppButton(
                pluginLocalization.string("Overwrite"),
                systemImage: "square.and.pencil",
                style: .warning,
                size: .small
            ) {
                isPresented = false
                onOverwrite()
            }
        }
    }

    // MARK: - Conflict card

    private func conflictCard(_ conflict: RowConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                kindBadge(conflict.kind)
                Text(conflict.target.isDelete ? pluginLocalization.string("Delete") : pluginLocalization.string("Update"))
                    .font(.appMicro)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
            conflictDetail(conflict)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.appSubtleBorder.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private func kindBadge(_ kind: RowConflictKind) -> some View {
        let label: String
        let color: Color
        let icon: String
        switch kind {
        case .changed:
            label = pluginLocalization.string("Changed by another client")
            color = theme.warning
            icon = "pencil.line"
        case .missing:
            label = pluginLocalization.string("Row missing")
            color = theme.error
            icon = "questionmark.circle"
        case .ambiguous:
            label = pluginLocalization.string("Ambiguous match")
            color = theme.error
            icon = "exclamationmark.triangle"
        }
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(.appMicro)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder
    private func conflictDetail(_ conflict: RowConflict) -> some View {
        switch conflict.kind {
        case .changed:
            diffTable(conflict)
        case .missing:
            Text(pluginLocalization.string("The row no longer exists, or no longer matches its original values (a table without a primary key is located by matching all columns)."))
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .ambiguous:
            Text(pluginLocalization.string("The row locator matched multiple rows. This table has duplicate rows and no primary key, so a single target cannot be determined."))
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Diff

    private func diffTable(_ conflict: RowConflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(pluginLocalization.string("Column"))
                    .frame(width: 120, alignment: .leading)
                Text(pluginLocalization.string("Original"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(pluginLocalization.string("Current"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(pluginLocalization.string("Your edit"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.appMicroEmphasized)
            .foregroundStyle(theme.textTertiary)

            ForEach(conflict.changedColumns, id: \.self) { column in
                diffRow(
                    column: column,
                    original: conflict.target.originalRow[column],
                    current: conflict.currentRow?[column],
                    yours: conflict.target.columnUpdates[column] ?? conflict.target.originalRow[column]
                )
            }
        }
    }

    private func diffRow(column: String, original: DatabaseValue?, current: DatabaseValue?, yours: DatabaseValue?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(column)
                .font(.appMicro)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 120, alignment: .leading)
            Text(displayText(original))
                .font(.monospaced(.caption)())
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(displayText(current))
                .font(.monospaced(.caption)())
                .foregroundStyle(theme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(displayText(yours))
                .font(.monospaced(.caption)())
                .foregroundStyle(theme.success)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(2)
    }

    private func displayText(_ value: DatabaseValue?) -> String {
        guard let value else { return "—" }
        if value == .null { return "NULL" }
        return value.description
    }
}