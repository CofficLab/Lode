import LumiUI
import SwiftUI

/// 密码来源交互闸门的统一呈现：askEveryTime 的密码询问 sheet 与 command 的确认对话框。
///
/// 同一份 VM 请求可能被两个上下文观察到——工作区（侧栏点击连接）与连接表单（Test Connection）。
/// 由 `isActive` 决定当前上下文是否呈现，避免两层 sheet 同时呈现同一请求而冲突：
/// 表单展示时由表单呈现（`isActive == true`），工作区让位（`isActive == false`）。
struct PasswordSourceGates: ViewModifier {
    @ObservedObject var viewModel: DatabaseViewModel
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { isActive && viewModel.passwordPrompt != nil },
                set: { if !$0 { viewModel.resolvePasswordPrompt(nil) } }
            )) {
                if let request = viewModel.passwordPrompt {
                    PasswordPromptSheet(request: request, viewModel: viewModel)
                }
            }
            .confirmationDialog(
                pluginLocalization.string("Run password command?"),
                isPresented: Binding(
                    get: { isActive && viewModel.commandConfirmation != nil },
                    set: { if !$0 { viewModel.resolveCommandConfirmation(false) } }
                ),
                titleVisibility: .visible
            ) {
                Button(pluginLocalization.string("Run Command")) { viewModel.resolveCommandConfirmation(true) }
                Button(pluginLocalization.string("Cancel"), role: .cancel) { viewModel.resolveCommandConfirmation(false) }
            } message: {
                if let request = viewModel.commandConfirmation {
                    Text(pluginLocalization.string("This connection runs a command on your Mac to retrieve its password."))
                    Text(request.command).font(.monospaced(.caption)())
                }
            }
    }
}

/// askEveryTime 来源的密码询问面板：密码仅存内存，随连接副本下发，绝不落盘。
struct PasswordPromptSheet: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    let request: DatabaseViewModel.PasswordPromptRequest
    @ObservedObject var viewModel: DatabaseViewModel
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pluginLocalization.string("Enter Password"))
                .font(.appTitle)
                .foregroundColor(theme.textPrimary)
            Text(String(format: pluginLocalization.string("Connection '%@' asks for its password each time."), request.connectionName))
                .font(.appBody)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let username = request.username, !username.isEmpty {
                Text(String(format: pluginLocalization.string("User: %@"), username))
                    .font(.appCaption)
                    .foregroundColor(theme.textTertiary)
            }
            GlassTextField(title: pluginLocalization.string("Password"), text: $password, placeholder: "••••••••", isSecure: true, allowsReveal: true)
            HStack {
                AppButton(pluginLocalization.string("Cancel"), style: .ghost, fillsWidth: true) {
                    viewModel.resolvePasswordPrompt(nil)
                }
                AppButton(pluginLocalization.string("Connect"), style: .primary, fillsWidth: true) {
                    viewModel.resolvePasswordPrompt(password)
                }
            }
        }
        .padding()
        .frame(width: 360)
    }
}