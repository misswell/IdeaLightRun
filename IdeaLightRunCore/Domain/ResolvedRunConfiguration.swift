import Foundation

/// §5: 配置解析结果——宏、环境文件、Working Directory 都已落地，
/// 后续阶段（组装命令行、CLI 的 `resolve` 命令）只读这份结果，不再各自展开宏。
public struct ResolvedRunConfiguration: Sendable {
    public var source: RunConfiguration
    public var mainClass: String?
    public var module: ProjectModule?
    public var jdk: JDKInstallation?

    public var vmArguments: [String]
    public var programArguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL

    /// 解析期间产生的告警（含父配置的告警）。致命问题不会走到这里，直接抛错。
    public var warnings: [ConfigurationWarning]
    /// 实际加载的环境文件路径，只含路径不含内容（§17）。
    public var loadedEnvironmentFiles: [String]

    public init(
        source: RunConfiguration,
        mainClass: String? = nil,
        module: ProjectModule? = nil,
        jdk: JDKInstallation? = nil,
        vmArguments: [String] = [],
        programArguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL,
        warnings: [ConfigurationWarning] = [],
        loadedEnvironmentFiles: [String] = []
    ) {
        self.source = source
        self.mainClass = mainClass
        self.module = module
        self.jdk = jdk
        self.vmArguments = vmArguments
        self.programArguments = programArguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.warnings = warnings
        self.loadedEnvironmentFiles = loadedEnvironmentFiles
    }
}
