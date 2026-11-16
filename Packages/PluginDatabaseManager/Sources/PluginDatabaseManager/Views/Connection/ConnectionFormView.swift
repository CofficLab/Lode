import LumiUI
import SwiftUI

/// 连接表单：同时支持「新建」与「编辑」。
///
/// - 新建：收集字段 → `viewModel.addConfig`。
/// - 编辑：从现有配置回填 → `viewModel.updateConfig`（保留 id；密码留空时沿用旧密码）。
///
/// 编辑模式下的密码处理：表单里始终留空（不回显明文），保存时空值表示「不改密码」。
/// 用户可手动输入新密码来覆盖。
struct ConnectionFormView: View {
    @LumiUI.LumiTheme private var theme: any LumiUITheme

    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool

    /// 编辑模式下的原配置；nil 表示新建。
    let editing: DatabaseConfig?

    @State private var name = ""
    @State private var type: DatabaseType = .sqlite
    @State private var host = ""
    @State private var portText = ""
    @State private var database = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sqlitePath = ""
    @State private var sslOption: ConnectionSSLOption = .require
    @State private var safeMode: ConnectionSafeMode = .off
    @State private var sshEnabled = false
    @State private var sshHost = ""
    @State private var sshPortText = ""
    @State private var sshUsername = ""
    @State private var sshAuthMethod: SSHAuthMethod = .password
    @State private var sshPassword = ""
    @State private var sshPrivateKeyPath = ""
    @State private var sshPassphrase = ""
    @State private var caCertPath = ""
    @State private var clientCertPath = ""
    @State private var clientKeyPath = ""
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSuccess = false

    init(viewModel: DatabaseViewModel, isPresented: Binding<Bool>, editing: DatabaseConfig? = nil) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self.editing = editing
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.appTitle)
                .foregroundColor(theme.textPrimary)

            AppCard {
                VStack(alignment: .leading, spacing: 8) {
                    GlassTextField(title: "Connection Name", text: $name, placeholder: pluginLocalization.string("My Database"))

                    HStack {
                        Text(pluginLocalization.string("Database Type"))
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Picker("", selection: $type) {
                            ForEach(DatabaseType.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                        .disabled(editing != nil)  // 编辑模式下不切换类型，避免配置语义错乱
                    }

                    if type == .sqlite {
                        GlassTextField(title: pluginLocalization.string("Database Path"), text: $sqlitePath, placeholder: "/path/to/db.sqlite")
                    } else {
                        GlassTextField(title: pluginLocalization.string("Host"), text: $host, placeholder: "127.0.0.1")
                        GlassTextField(title: pluginLocalization.string("Port"), text: $portText, placeholder: "\(type.defaultPort ?? 0)")
                        GlassTextField(title: pluginLocalization.string("Database"), text: $database, placeholder: databasePlaceholder)
                        GlassTextField(title: pluginLocalization.string("Username"), text: $username, placeholder: type == .redis ? "default" : "user")
                        GlassTextField(title: pluginLocalization.string("Password"), text: $password, placeholder: passwordPlaceholder, isSecure: true, allowsReveal: true)

                        if type.capabilities.supportsSSL {
                            sslPicker
                            if sslOption != .disable {
                                tlsCertFields
                            }
                        }
                        if type.capabilities.supportsSSH {
                            sshSection
                        }
                    }

                    safeModePicker
                }
            }

            HStack {
                AppButton(pluginLocalization.string("Cancel"), style: .ghost, fillsWidth: true, action: { isPresented = false })
                AppButton(pluginLocalization.string("Test Connection"), style: .secondary, fillsWidth: true, action: testConnection)
                    .disabled(!canTestConnection())
                AppButton(saveLabel, style: .primary, fillsWidth: true, action: save)
                    .disabled(!isValid())
            }

            if let msg = testMessage {
                HStack {
                    Image(systemName: testSuccess ? "checkmark.circle" : "xmark.octagon")
                        .foregroundColor(testSuccess ? theme.success : theme.error)
                    Text(msg)
                        .foregroundColor(testSuccess ? theme.success : theme.error)
                    if isTesting {
                        Spacer()
                        ProgressView().scaleEffect(0.5)
                    }
                }
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear(perform: prefill)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var sslPicker: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pluginLocalization.string("SSL / TLS"))
                    .font(.appCaption)
                    .foregroundColor(theme.textSecondary)
                Text(pluginLocalization.string(sslOption.helpText))
                    .font(.appMicro)
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("", selection: $sslOption) {
                ForEach(ConnectionSSLOption.allCases, id: \.self) { mode in
                    Text(pluginLocalization.string(mode.displayTitle)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
        }
    }

    /// TLS 证书材料：自定义 CA（自签服务器 verify-ca/verify-full 所需）。
    /// 客户端证书/私钥用于双向 TLS，仅 MySQL/PostgreSQL（NIOSSL）支持；
    /// Redis 走 Network.framework，仅做服务端认证。
    @ViewBuilder
    private var tlsCertFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassTextField(title: pluginLocalization.string("CA Certificate Path"), text: $caCertPath, placeholder: pluginLocalization.string("Optional, for self-signed servers"))
            if type != .redis {
                GlassTextField(title: pluginLocalization.string("Client Certificate Path"), text: $clientCertPath, placeholder: pluginLocalization.string("Optional, for mutual TLS"))
                GlassTextField(title: pluginLocalization.string("Client Key Path"), text: $clientKeyPath, placeholder: pluginLocalization.string("Optional, for mutual TLS"))
            }
        }
    }

    /// SSH 跳板隧道：开关 + 折叠字段。仅对支持 SSH 的网络引擎显示。
    /// 编辑模式下密码/passphrase 不回显，留空保存表示沿用已存值。
    @ViewBuilder
    private var sshSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $sshEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pluginLocalization.string("SSH Tunnel"))
                        .font(.appCaption)
                        .foregroundColor(theme.textSecondary)
                    Text(pluginLocalization.string("Connect through an SSH jump host"))
                        .font(.appMicro)
                        .foregroundColor(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(theme.primary)

            if sshEnabled {
                GlassTextField(title: pluginLocalization.string("SSH Host"), text: $sshHost, placeholder: "bastion.example.com")
                GlassTextField(title: pluginLocalization.string("SSH Port"), text: $sshPortText, placeholder: "22")
                GlassTextField(title: pluginLocalization.string("SSH Username"), text: $sshUsername, placeholder: "user")

                HStack {
                    Text(pluginLocalization.string("Authentication"))
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Picker("", selection: $sshAuthMethod) {
                        ForEach(SSHAuthMethod.allCases, id: \.self) { method in
                            Text(method.displayTitle).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                switch sshAuthMethod {
                case .password:
                    GlassTextField(title: pluginLocalization.string("SSH Password"), text: $sshPassword, placeholder: sshPasswordPlaceholder, isSecure: true, allowsReveal: true)
                case .privateKey:
                    GlassTextField(title: pluginLocalization.string("Private Key Path"), text: $sshPrivateKeyPath, placeholder: "~/.ssh/id_ed25519")
                    GlassTextField(title: pluginLocalization.string("Passphrase"), text: $sshPassphrase, placeholder: pluginLocalization.string("Optional"), isSecure: true, allowsReveal: true)
                case .agent:
                    Text(pluginLocalization.string("Uses identities from your SSH agent (SSH_AUTH_SOCK)."))
                        .font(.appMicro)
                        .foregroundColor(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 安全模式选择：off / confirmWrites / readOnly，适用于所有引擎（含 SQLite）。
    @ViewBuilder
    private var safeModePicker: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pluginLocalization.string("Safe Mode"))
                    .font(.appCaption)
                    .foregroundColor(theme.textSecondary)
                Text(pluginLocalization.string(safeMode.helpText))
                    .font(.appMicro)
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("", selection: $safeMode) {
                ForEach(ConnectionSafeMode.allCases, id: \.self) { mode in
                    Text(pluginLocalization.string(mode.displayTitle)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
        }
    }

    // MARK: - Derived

    private var title: String {
        editing == nil
            ? pluginLocalization.string("Add Connection")
            : pluginLocalization.string("Edit Connection")
    }

    private var saveLabel: String {
        editing == nil ? "Add" : "Save"
    }

    private var passwordPlaceholder: String {
        editing == nil ? "••••••••" : pluginLocalization.string("Leave blank to keep current")
    }

    private var databasePlaceholder: String {
        switch type {
        case .redis: return "0"
        case .postgresql: return "postgres"
        case .mysql: return "testdb"
        case .sqlite: return ""
        }
    }

    private var sshPasswordPlaceholder: String {
        editing == nil ? "••••••••" : pluginLocalization.string("Leave blank to keep current")
    }

    /// 编辑模式下 SSH 密码留空表示沿用已存值；新建时留空即为空（校验会拦截）。
    private var effectiveSSHPassword: String? {
        if !sshPassword.isEmpty { return sshPassword }
        return editing?.sshConfig?.password
    }

    private var effectiveSSHPassphrase: String? {
        if !sshPassphrase.isEmpty { return sshPassphrase }
        return editing?.sshConfig?.passphrase
    }

    // MARK: - Lifecycle

    private func prefill() {
        guard let editing else { return }
        name = editing.name
        type = editing.type
        host = editing.host ?? ""
        portText = editing.port.map(String.init) ?? ""
        database = editing.database
        username = editing.username ?? ""
        sqlitePath = editing.type == .sqlite ? editing.database : ""
        if let ssl = editing.sslOption {
            sslOption = ssl
        }
        if let tls = editing.tlsConfig {
            caCertPath = tls.caCertPath ?? ""
            clientCertPath = tls.clientCertPath ?? ""
            clientKeyPath = tls.clientKeyPath ?? ""
        }
        safeMode = editing.safeMode
        if let ssh = editing.sshConfig {
            sshEnabled = true
            sshHost = ssh.host
            sshPortText = String(ssh.port)
            sshUsername = ssh.username
            sshAuthMethod = ssh.authMethod
            sshPrivateKeyPath = ssh.privateKeyPath ?? ""
            // 密码与 passphrase 不回显；留空保存时沿用已存值。
        }
    }

    // MARK: - Actions

    private func isValid() -> Bool {
        (try? makeConnectionConfig()) != nil
    }

    private func canTestConnection() -> Bool {
        (try? makeConnectionConfig(defaultName: "Test")) != nil
    }

    private func testConnection() {
        let config: DatabaseConfig
        do {
            config = try makeConnectionConfig(defaultName: "Test")
        } catch {
            testMessage = error.localizedDescription
            testSuccess = false
            return
        }

        isTesting = true
        testMessage = nil
        testSuccess = false
        Task {
            do {
                try await viewModel.testConnection(config: config)
                testMessage = pluginLocalization.string("Connection succeeded")
                testSuccess = true
            } catch {
                testMessage = error.localizedDescription
                testSuccess = false
            }
            isTesting = false
        }
    }

    private func save() {
        do {
            let config = try makeConnectionConfig()
            if editing != nil {
                // 编辑：保留原 id，把新字段（含 SSL）合并回去
                viewModel.updateConfig(config)
            } else {
                viewModel.addConfig(config)
            }
            isPresented = false
        } catch {
            testMessage = error.localizedDescription
            testSuccess = false
        }
    }

    private func makeConnectionConfig(defaultName: String? = nil) throws -> DatabaseConfig {
        let draft = try DatabaseConnectionDraft(
            name: name,
            type: type,
            host: host,
            portText: portText,
            database: database,
            username: username,
            password: password,
            sqlitePath: sqlitePath
        ).makeConfig(defaultName: defaultName)

        // 编辑模式：保留原 id（makeConfig 会生成新 UUID）
        var config = draft
        if let editing {
            config.id = editing.id
        }
        // SSL 仅对支持 TLS 的网络库有意义
        if type.capabilities.supportsSSL {
            config = config.withSSLOption(sslOption)
            // TLS 证书材料：Redis 走 Network.framework，仅服务端认证，忽略客户端证书/密钥。
            let tls = ConnectionTLSConfig(
                caCertPath: caCertPath.isEmpty ? nil : caCertPath,
                clientCertPath: type == .redis ? nil : (clientCertPath.isEmpty ? nil : clientCertPath),
                clientKeyPath: type == .redis ? nil : (clientKeyPath.isEmpty ? nil : clientKeyPath)
            )
            config = config.withTLSConfig(try tls.validated())
        } else {
            config = config.withSSLOption(nil)
            config = config.withTLSConfig(nil)
        }
        // SSH 隧道仅对支持的网络引擎有意义；启用时校验字段，关闭时移除该键。
        if type.capabilities.supportsSSH, sshEnabled {
            let trimmedPort = sshPortText.trimmingCharacters(in: .whitespaces)
            let sshPort: Int
            if trimmedPort.isEmpty {
                sshPort = 22
            } else if let parsed = Int(trimmedPort) {
                sshPort = parsed
            } else {
                throw ConnectionSSHConfigError.invalidPort
            }
            let ssh = ConnectionSSHConfig(
                host: sshHost,
                port: sshPort,
                username: sshUsername,
                authMethod: sshAuthMethod,
                password: effectiveSSHPassword,
                privateKeyPath: sshPrivateKeyPath.isEmpty ? nil : sshPrivateKeyPath,
                passphrase: effectiveSSHPassphrase
            )
            config = config.withSSHConfig(try ssh.validated())
        } else {
            config = config.withSSHConfig(nil)
        }
        // 安全模式适用于所有引擎（off 档移除该键，回退默认）。
        config = config.withSafeMode(safeMode)
        return config
    }
}
