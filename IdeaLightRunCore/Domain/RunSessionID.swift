import Foundation

/// §P0-1: 一次运行会话的身份。以前只用 `type + 配置名`（configKey）当会话键，
/// 两个项目里同名配置会互相覆盖会话。现在：
/// - projectID：项目根目录规范化绝对路径
/// - configurationID：type + 配置名（与 RunConfiguration.uniqueKey 一致）
/// - instanceID：每次启动新生成，allowParallelRun 的多实例由此区分
/// Configuration（配置身份）与 Instance（运行实例）是两层：同一配置可以先后/同时
/// 有多个 instance。
public struct RunSessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let projectID: String
    public let configurationID: String
    public let instanceID: UUID

    public init(projectID: String, configurationID: String, instanceID: UUID = UUID()) {
        self.projectID = projectID
        self.configurationID = configurationID
        self.instanceID = instanceID
    }

    /// 配置级身份（不含实例）：同一项目同一配置的所有实例共享。
    public var configurationScopeKey: String {
        "\(projectID)::\(configurationID)"
    }

    public var description: String {
        "\(configurationID)#\(instanceID.uuidString.prefix(8)) @ \(projectID)"
    }
}
