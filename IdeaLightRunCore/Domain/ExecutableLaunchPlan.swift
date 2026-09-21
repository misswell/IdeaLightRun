import Foundation

/// §7: 通用启动计划。下游（进程会话、GUI、CLI）只看到"可执行文件 + 参数"，
/// 不再知道 Java / -cp / Main Class / Maven / Gradle / JAR，
/// 这样 JAR Application 与 Maven/Gradle Run Configuration 才能复用同一条进程管线。
public struct ExecutableLaunchPlan: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    /// 展示用（"复制启动命令"）；执行永远只用 `arguments`，绝不解析这个字符串。
    public var displayCommand: String
    /// 计划自带的临时文件（@argfile、classpath manifest jar）。
    /// 进程进入终态后由 `ManagedProcessSession` 删除，调用方不需要自己收尾。
    public var temporaryArtifacts: [URL]

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        displayCommand: String? = nil,
        temporaryArtifacts: [URL] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.displayCommand = displayCommand
            ?? Self.quote([executable.path] + arguments)
        self.temporaryArtifacts = temporaryArtifacts
    }

    /// 每个参数是一个整体，含空格的只在两端加引号——不做 shell 转义，因为它只用于展示。
    static func quote(_ parts: [String]) -> String {
        parts.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}
