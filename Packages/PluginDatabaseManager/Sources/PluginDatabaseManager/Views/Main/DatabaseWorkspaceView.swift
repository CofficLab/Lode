import LumiUI
import SwiftUI

/// 数据库工作区根视图：在主面板外层套一个可收起的右侧 Inspector。
///
/// 宿主 App 没有原生的 inspector 区域，这里用 macOS 14+ 的 `.inspector` 修饰符
/// 在 viewContainer 自己的 PanelBody 内部切出右侧面板，既不污染宿主布局，
/// 又能与 ``DatabaseViewModel`` 共享同一份状态。
///
/// Inspector 当前的内容是占位（``DatabaseInspectorView``），后续 Phase 会逐步填入：
/// - Phase 2/3：选中表的结构详情与行详情
/// - Phase 4：EXPLAIN 可视化
/// - Phase 6：ER 关系图
public struct DatabaseWorkspaceView: View {
    @ObservedObject var viewModel: DatabaseViewModel

    public init(viewModel: DatabaseViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // macOS 13 兼容实现：`.inspector(isPresented:)` 是 macOS 14 独占 API，
        // 这里改用 HStack 自行实现右侧可开关面板（宽度与 `.inspectorColumnWidth`
        // 的 240...560 区间保持一致）。
        HStack(spacing: 0) {
            MainView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.inspectorVisible {
                AppDivider()
                    .frame(width: 1)
                DatabaseInspectorView(viewModel: viewModel)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 560)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                if viewModel.isConnected, viewModel.selectedConfig?.type.capabilities.supportsForeignKeys == true {
                    Button {
                        viewModel.isERDiagramPresented = true
                    } label: {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pluginLocalization.string("ER Diagram"))
                }
                Button {
                    viewModel.toggleInspector()
                } label: {
                    Image(systemName: viewModel.inspectorVisible ? "sidebar.trailing.collapse" : "sidebar.trailing")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pluginLocalization.string("Toggle Inspector"))
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .confirmationDialog(
            writeConfirmationTitle,
            isPresented: Binding(
                get: { viewModel.writeConfirmation != nil },
                set: { if !$0 { viewModel.resolveWriteConfirmation(false) } }
            ),
            titleVisibility: .visible
        ) {
            Button(writeConfirmationButtonTitle) { viewModel.resolveWriteConfirmation(true) }
            Button(pluginLocalization.string("Cancel"), role: .cancel) { viewModel.resolveWriteConfirmation(false) }
        } message: {
            if let request = viewModel.writeConfirmation {
                Text(pluginLocalization.string("This connection asks for confirmation before writes."))
                Text("\(request.writeCount) " + pluginLocalization.string("write statement(s) will be executed."))
                if let preview = request.previewSQL {
                    Text(preview).font(.monospaced(.caption)())
                }
            }
        }
        .modifier(PasswordSourceGates(viewModel: viewModel, isActive: !viewModel.isConnectionFormPresented))
        .sheet(isPresented: $viewModel.isERDiagramPresented) {
            ERDiagramView(viewModel: viewModel, isPresented: $viewModel.isERDiagramPresented)
        }
        .sheet(isPresented: $viewModel.isQueryPlanPresented) {
            QueryPlanView(viewModel: viewModel, isPresented: $viewModel.isQueryPlanPresented)
        }
    }

    // MARK: - 写确认文案

    private var writeConfirmationTitle: String {
        switch viewModel.writeConfirmation?.kind {
        case .query: return pluginLocalization.string("Run this write statement?")
        case .batch: return pluginLocalization.string("Run these write statements?")
        case .tableEdit: return pluginLocalization.string("Save changes to the database?")
        case .schemaChange: return pluginLocalization.string("Apply structure changes?")
        case nil: return pluginLocalization.string("Confirm write")
        }
    }

    private var writeConfirmationButtonTitle: String {
        switch viewModel.writeConfirmation?.kind {
        case .query, .batch: return pluginLocalization.string("Run")
        case .tableEdit: return pluginLocalization.string("Save")
        case .schemaChange: return pluginLocalization.string("Apply Changes")
        case nil: return pluginLocalization.string("Confirm")
        }
    }
}
