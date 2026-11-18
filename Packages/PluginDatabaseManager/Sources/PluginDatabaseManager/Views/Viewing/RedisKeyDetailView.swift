import SwiftUI
import LumiUI

/// Redis 键类型化详情面板：按类型查看/编辑值，查看与修改 TTL，删除键。
///
/// 由侧边栏键树点击叶子键打开（``DatabaseViewModel/openRedisKey(_:)``），
/// 取代命令编辑器占据主区；返回按钮回到编辑器。所有写操作经
/// ``DatabaseViewModel/applyRedisEdit(_:)`` 走写闸门（confirmWrites 确认 / readOnly 拒绝）。
struct RedisKeyDetailView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme
    @ObservedObject var viewModel: DatabaseViewModel

    @State private var stringDraft: String = ""
    @State private var form: RedisEditForm?
    @State private var valueViewer: ValueViewerRequest?

    private var key: String { viewModel.selectedRedisKey?.key ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDivider()
            if let error = viewModel.redisValueError {
                AppErrorBanner(message: LocalizedStringKey(error))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
        .sheet(item: $form) { form in
            RedisEditFormSheet(form: form, viewModel: viewModel)
        }
        .sheet(item: $valueViewer) { request in
            CellValueViewerSheet(column: request.column, value: request.value)
        }
        .onAppear { syncStringDraft() }
        .onChange(of: viewModel.selectedRedisValue) { _ in syncStringDraft() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            AppIconButton(systemImage: "chevron.left", label: pluginLocalization.string("Back"), size: .compact) {
                viewModel.closeRedisKey()
            }
            .help(pluginLocalization.string("Back to the command editor"))

            Image(systemName: viewModel.selectedRedisKey?.type.systemImage ?? "key")
                .foregroundStyle(theme.primary)
            Text(key)
                .font(.monospaced(.appBodyEmphasized)())
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let info = viewModel.selectedRedisKey {
                AppTag(info.type.displayTitle, systemImage: nil, style: .subtle)
                AppTag(ttlLabel(info.ttl), systemImage: "timer", style: .subtle)
            }

            Spacer(minLength: 8)

            if viewModel.isLoadingRedisValue {
                ProgressView().scaleEffect(0.5)
            }
            AppIconButton(systemImage: "arrow.clockwise", label: pluginLocalization.string("Refresh"), size: .compact) {
                Task { await viewModel.refreshSelectedRedisValue() }
            }
            .help(pluginLocalization.string("Refresh this key"))
            AppIconButton(systemImage: "timer", label: pluginLocalization.string("Set TTL"), size: .compact) {
                form = .ttl(key: key, current: viewModel.selectedRedisKey?.ttl ?? -1)
            }
            .help(pluginLocalization.string("Set or clear the expiry"))
            AppIconButton(systemImage: "trash", label: pluginLocalization.string("Delete Key"), size: .compact) {
                Task { await viewModel.applyRedisEdit(.delete(key: key)) }
            }
            .help(pluginLocalization.string("Delete this key"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 12 + viewModel.workspaceOverlayTrailingInset)
        .frame(height: 48)
    }

    private func ttlLabel(_ ttl: Int) -> String {
        switch ttl {
        case -1: return pluginLocalization.string("No expiry")
        case -2: return pluginLocalization.string("Missing")
        default: return String(format: pluginLocalization.string("TTL: %d s"), ttl)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingRedisValue && viewModel.selectedRedisValue == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let info = viewModel.selectedRedisKey, info.type == .none {
            AppEmptyState(
                icon: "questionmark.circle",
                title: pluginLocalization.string("This key no longer exists."),
                description: ""
            )
        } else {
            switch viewModel.selectedRedisValue {
            case .string(let value): stringSection(value)
            case .hash(let entries): hashSection(entries)
            case .list(let values): listSection(values)
            case .set(let values): setSection(values)
            case .zset(let entries): zsetSection(entries)
            case .stream(let entries): streamSection(entries)
            case nil:
                AppEmptyState(icon: "key", title: pluginLocalization.string("No value"), description: "")
            }
        }
    }

    // MARK: - String

    @ViewBuilder
    private func stringSection(_ value: DatabaseValue) -> some View {
        if case .data(let data) = value {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(pluginLocalization.string("Binary value"))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    AppButton(pluginLocalization.string("View value"), systemImage: "eye", style: .secondary, size: .small) {
                        valueViewer = ValueViewerRequest(column: key, value: value)
                    }
                }
                ScrollView {
                    Text("0x" + HexFormatter.hexString(data))
                        .font(.monospaced(.appMicro)())
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        } else {
            VStack(spacing: 8) {
                TextEditor(text: $stringDraft)
                    .font(.monospaced(.appCaption)())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(theme.surface)
                    .border(theme.appSubtleBorder)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text(String(format: pluginLocalization.string("%d characters"), stringDraft.count))
                        .font(.appMicro)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    AppButton(pluginLocalization.string("Save"), systemImage: "checkmark", style: .primary, size: .small) {
                        Task { await viewModel.applyRedisEdit(.setString(key: key, value: stringDraft)) }
                    }
                }
            }
            .padding(12)
        }
    }

    private func syncStringDraft() {
        if case .string(let value) = viewModel.selectedRedisValue {
            if case .string(let s) = value { stringDraft = s } else { stringDraft = "" }
        } else {
            stringDraft = ""
        }
    }

    // MARK: - Hash

    private func hashSection(_ entries: [RedisHashEntry]) -> some View {
        VStack(spacing: 0) {
            sectionToolbar(title: pluginLocalization.string("Fields"), count: entries.count, addTitle: pluginLocalization.string("Add Field")) {
                form = .hashField(key: key, existing: nil)
            }
            columnHeaders([pluginLocalization.string("Field"), pluginLocalization.string("Value")])
            if entries.isEmpty {
                emptyRow(pluginLocalization.string("No fields"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries, id: \.field) { entry in
                            valueRow(
                                primary: entry.field,
                                secondary: entry.value.description,
                                onEdit: { form = .hashField(key: key, existing: entry) },
                                onView: { valueViewer = ValueViewerRequest(column: entry.field, value: entry.value) },
                                onDelete: { Task { await viewModel.applyRedisEdit(.hashDelete(key: key, field: entry.field)) } }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - List

    private func listSection(_ values: [DatabaseValue]) -> some View {
        VStack(spacing: 0) {
            sectionToolbar(title: pluginLocalization.string("Items"), count: values.count, addTitle: pluginLocalization.string("Append Item")) {
                form = .listItem(key: key, index: nil, existing: nil)
            }
            if values.isEmpty {
                emptyRow(pluginLocalization.string("No items"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(values.indices, id: \.self) { index in
                            valueRow(
                                primary: "\(index)",
                                secondary: values[index].description,
                                onEdit: { form = .listItem(key: key, index: index, existing: values[index].description) },
                                onView: { valueViewer = ValueViewerRequest(column: "\(index)", value: values[index]) },
                                onDelete: { Task { await viewModel.applyRedisEdit(.listRemove(key: key, value: values[index].description)) } }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Set

    private func setSection(_ values: [DatabaseValue]) -> some View {
        VStack(spacing: 0) {
            sectionToolbar(title: pluginLocalization.string("Members"), count: values.count, addTitle: pluginLocalization.string("Add Member")) {
                form = .setMember(key: key)
            }
            if values.isEmpty {
                emptyRow(pluginLocalization.string("No members"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(values.indices, id: \.self) { index in
                            valueRow(
                                primary: values[index].description,
                                secondary: nil,
                                onEdit: nil,
                                onView: { valueViewer = ValueViewerRequest(column: pluginLocalization.string("Member"), value: values[index]) },
                                onDelete: { Task { await viewModel.applyRedisEdit(.setRemove(key: key, member: values[index].description)) } }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sorted Set

    private func zsetSection(_ entries: [RedisZSetEntry]) -> some View {
        VStack(spacing: 0) {
            sectionToolbar(title: pluginLocalization.string("Members"), count: entries.count, addTitle: pluginLocalization.string("Add Member")) {
                form = .zsetMember(key: key, existing: nil)
            }
            columnHeaders([pluginLocalization.string("Member"), pluginLocalization.string("Score")])
            if entries.isEmpty {
                emptyRow(pluginLocalization.string("No members"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            valueRow(
                                primary: entry.member.description,
                                secondary: String(entry.score),
                                onEdit: { form = .zsetMember(key: key, existing: entry) },
                                onView: { valueViewer = ValueViewerRequest(column: pluginLocalization.string("Member"), value: entry.member) },
                                onDelete: { Task { await viewModel.applyRedisEdit(.zsetRemove(key: key, member: entry.member.description)) } }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Stream

    private func streamSection(_ entries: [RedisStreamEntry]) -> some View {
        VStack(spacing: 0) {
            sectionToolbar(title: pluginLocalization.string("Entries"), count: entries.count, addTitle: pluginLocalization.string("Add Entry")) {
                form = .streamEntry(key: key)
            }
            if entries.isEmpty {
                emptyRow(pluginLocalization.string("No entries"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(entries, id: \.id) { entry in
                            streamEntryRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func streamEntryRow(_ entry: RedisStreamEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.primary)
                Text(entry.id)
                    .font(.monospaced(.appMicroEmphasized)())
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 4)
                AppIconButton(systemImage: "trash", label: pluginLocalization.string("Delete"), size: .compact) {
                    Task { await viewModel.applyRedisEdit(.streamDelete(key: key, id: entry.id)) }
                }
            }
            ForEach(entry.fields, id: \.field) { field in
                HStack(spacing: 6) {
                    Text(field.field)
                        .font(.appMicroEmphasized)
                        .foregroundStyle(theme.textSecondary)
                    Text(field.value.description)
                        .font(.appMicro)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
            }
        }
        .padding(8)
        .background(theme.appSubtleBorder.opacity(0.4), in: .rect(cornerRadius: 6))
    }

    // MARK: - Shared rows

    private func sectionToolbar(title: String, count: Int, addTitle: String, onAdd: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.appBodyEmphasized)
                .foregroundStyle(theme.textPrimary)
            AppTag("\(count)", style: .subtle)
            Spacer()
            AppButton(addTitle, systemImage: "plus", style: .secondary, size: .small, action: onAdd)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func columnHeaders(_ titles: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.appMicroEmphasized)
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer().frame(width: 96)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(theme.appSubtleBorder.opacity(0.3))
    }

    private func valueRow(
        primary: String,
        secondary: String?,
        onEdit: (() -> Void)?,
        onView: (() -> Void)?,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(primary)
                .font(.monospaced(.appMicroEmphasized)())
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let secondary {
                Text(secondary)
                    .font(.monospaced(.appMicro)())
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 2) {
                if let onView {
                    AppIconButton(systemImage: "eye", label: pluginLocalization.string("View value"), size: .compact, action: onView)
                }
                if let onEdit {
                    AppIconButton(systemImage: "pencil", label: pluginLocalization.string("Edit"), size: .compact, action: onEdit)
                }
                AppIconButton(systemImage: "trash", label: pluginLocalization.string("Delete"), size: .compact, action: onDelete)
            }
            .frame(width: 96)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Edit form

/// 键编辑输入表单的描述（sheet item）。携带重建 ``RedisKeyEdit`` 所需的上下文。
enum RedisEditForm: Identifiable {
    case ttl(key: String, current: Int)
    case hashField(key: String, existing: RedisHashEntry?)
    case listItem(key: String, index: Int?, existing: String?)
    case setMember(key: String)
    case zsetMember(key: String, existing: RedisZSetEntry?)
    case streamEntry(key: String)

    var id: String {
        switch self {
        case .ttl(let key, _): return "ttl-\(key)"
        case .hashField(let key, let existing): return "hash-\(key)-\(existing?.field ?? "new")"
        case .listItem(let key, let index, _): return "list-\(key)-\(index.map(String.init) ?? "new")"
        case .setMember(let key): return "set-\(key)"
        case .zsetMember(let key, let existing): return "zset-\(key)-\(existing?.member.description ?? "new")"
        case .streamEntry(let key): return "stream-\(key)"
        }
    }
}

/// 通用键编辑表单：按 ``RedisEditForm`` 展示一/两个输入框，提交时构造写命令并经写闸门执行。
struct RedisEditFormSheet: View {
    let form: RedisEditForm
    @ObservedObject var viewModel: DatabaseViewModel

    @Environment(\.dismiss) private var dismiss
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    @State private var primary: String = ""
    @State private var secondary: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(theme.primary)
                Text(title)
                    .font(.appBodyEmphasized)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                AppIconButton(systemImage: "xmark", label: pluginLocalization.string("Close"), size: .compact) {
                    dismiss()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            AppDivider()

            VStack(alignment: .leading, spacing: 10) {
                fields
            }
            .padding(16)

            AppDivider()
            HStack {
                if case .ttl = form {
                    AppButton(pluginLocalization.string("Persist"), systemImage: "infinity", style: .secondary, size: .small) {
                        submit(.persist(key: formKey))
                    }
                    .help(pluginLocalization.string("Remove the expiry so the key never expires"))
                }
                Spacer()
                AppButton(pluginLocalization.string("Cancel"), style: .ghost, size: .small) { dismiss() }
                AppButton(pluginLocalization.string("Save"), systemImage: "checkmark", style: .primary, size: .small) {
                    if let edit = makeEdit() { submit(edit) }
                }
                .disabled(!canSave)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
        .frame(width: 440)
        .background(theme.surface)
        .onAppear { prefill() }
    }

    private var formKey: String {
        switch form {
        case .ttl(let key, _), .hashField(let key, _), .listItem(let key, _, _),
             .setMember(let key), .zsetMember(let key, _), .streamEntry(let key):
            return key
        }
    }

    private var title: String {
        switch form {
        case .ttl: return pluginLocalization.string("Set TTL")
        case .hashField(_, let existing): return existing == nil ? pluginLocalization.string("Add Field") : pluginLocalization.string("Edit Field")
        case .listItem(_, let index, _): return index == nil ? pluginLocalization.string("Append Item") : pluginLocalization.string("Edit Item")
        case .setMember: return pluginLocalization.string("Add Member")
        case .zsetMember(_, let existing): return existing == nil ? pluginLocalization.string("Add Member") : pluginLocalization.string("Edit Member")
        case .streamEntry: return pluginLocalization.string("Add Entry")
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch form {
        case .ttl:
            labeledField(pluginLocalization.string("Seconds"), text: $primary, placeholder: "60")
            Text(pluginLocalization.string("Seconds until the key expires."))
                .font(.appMicro)
                .foregroundStyle(theme.textTertiary)
        case .hashField(_, let existing):
            labeledField(pluginLocalization.string("Field"), text: $primary, placeholder: pluginLocalization.string("Field"), disabled: existing != nil)
            labeledField(pluginLocalization.string("Value"), text: $secondary, placeholder: pluginLocalization.string("Value"))
        case .listItem:
            labeledField(pluginLocalization.string("Value"), text: $primary, placeholder: pluginLocalization.string("Value"))
        case .setMember:
            labeledField(pluginLocalization.string("Member"), text: $primary, placeholder: pluginLocalization.string("Member"))
        case .zsetMember(_, let existing):
            labeledField(pluginLocalization.string("Member"), text: $primary, placeholder: pluginLocalization.string("Member"), disabled: existing != nil)
            labeledField(pluginLocalization.string("Score"), text: $secondary, placeholder: "1.0")
        case .streamEntry:
            labeledField(pluginLocalization.string("Field"), text: $primary, placeholder: pluginLocalization.string("Field"))
            labeledField(pluginLocalization.string("Value"), text: $secondary, placeholder: pluginLocalization.string("Value"))
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.appMicroEmphasized)
                .foregroundStyle(theme.textSecondary)
            GlassTextField(title: label, text: text, placeholder: placeholder)
                .disabled(disabled)
        }
    }

    private func prefill() {
        switch form {
        case .ttl(_, let current):
            primary = current >= 0 ? String(current) : ""
        case .hashField(_, let existing):
            primary = existing?.field ?? ""
            secondary = existing?.value.description ?? ""
        case .listItem(_, _, let existing):
            primary = existing ?? ""
        case .setMember:
            primary = ""
        case .zsetMember(_, let existing):
            primary = existing?.member.description ?? ""
            secondary = existing.map { String($0.score) } ?? ""
        case .streamEntry:
            primary = ""
            secondary = ""
        }
    }

    private var canSave: Bool {
        switch form {
        case .ttl: return Int(primary) != nil
        case .hashField: return !primary.isEmpty
        case .listItem: return true
        case .setMember: return !primary.isEmpty
        case .zsetMember: return !primary.isEmpty && Double(secondary) != nil
        case .streamEntry: return !primary.isEmpty
        }
    }

    private func makeEdit() -> RedisKeyEdit? {
        switch form {
        case .ttl(let key, _):
            guard let seconds = Int(primary) else { return nil }
            return .setTTL(key: key, seconds: seconds)
        case .hashField(let key, _):
            return .hashSet(key: key, field: primary, value: secondary)
        case .listItem(let key, let index, _):
            if let index { return .listSet(key: key, index: index, value: primary) }
            return .listPush(key: key, value: primary)
        case .setMember(let key):
            return .setAdd(key: key, member: primary)
        case .zsetMember(let key, _):
            guard let score = Double(secondary) else { return nil }
            return .zsetAdd(key: key, member: primary, score: score)
        case .streamEntry(let key):
            return .streamAdd(key: key, fields: [RedisHashEntry(field: primary, value: .string(secondary))])
        }
    }

    private func submit(_ edit: RedisKeyEdit) {
        dismiss()
        Task { await viewModel.applyRedisEdit(edit) }
    }
}