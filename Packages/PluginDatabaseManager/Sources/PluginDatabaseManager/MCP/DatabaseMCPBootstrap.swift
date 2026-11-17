import Foundation

/// MCP server 进程的装配入口。
///
/// 独立进程没有 App 的内存注册表，这里从应用域偏好读取已保存连接
/// （密码经 Keychain 回填，可能触发系统授权询问），并构造与 App 共享
/// 允许列表 / 审计日志存储的服务实例。
public enum DatabaseMCPBootstrap {
    /// 宿主 App 的 UserDefaults 域；CLI 进程经 suiteName 读取同一份配置。
    public static let appDomain = "com.coffic.lode"
    /// 测试/多实例隔离用：覆盖读取配置的偏好域。
    public static let appDomainEnvironmentKey = "LODE_MCP_APP_DOMAIN"

    public static func makeService() async -> (service: DatabaseAgentToolService, policy: DatabaseAgentAccessPolicy) {
        let domain = ProcessInfo.processInfo.environment[appDomainEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 } ?? appDomain
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        let registry = DatabaseAgentConnectionRegistry()
        for config in DatabaseConnectionStore.loadConfigs(defaults: defaults) {
            await registry.upsert(config)
        }
        let policy = DatabaseAgentAccessPolicy(defaults: defaults)
        let audit = DatabaseAgentAuditLog(defaults: defaults)
        let service = DatabaseAgentToolService(registry: registry, policy: policy, audit: audit)
        return (service, policy)
    }
}