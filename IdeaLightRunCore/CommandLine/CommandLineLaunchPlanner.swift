import Foundation

/// 命令行模式的项目级设置。它不是 IDEA 的 Run Configuration：
/// 命令由用户手写，随项目保存；Java 配置的解析与启动链路完全不受影响。
public struct CommandLineSettings: Equatable, Codable, Sendable {
    /// 「命令行」会话在运行会话表里的固定配置键。
    /// 这不是 IDEA 配置的 uniqueKey，不会与 `Type::Name` 形式的键冲突。
    public static let sessionConfigurationKey = "IdeaLightRunCommandLine::command-line"

    public var command: String
    /// 空值表示项目根。支持 `~`、`$PROJECT_DIR$` 与相对路径。
    public var workingDirectory: String
    /// 每行一条 `KEY=VALUE`，语义与 `.env` 相同（复用 DotEnvParser）。
    public var environmentText: String

    public init(
        command: String = "",
        workingDirectory: String = "",
        environmentText: String = ""
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentText = environmentText
    }

    public static let empty = CommandLineSettings()

    public var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isRunnable: Bool {
        !trimmedCommand.isEmpty
    }
}

/// 把用户输入的命令转成统一 `ExecutableLaunchPlan`，之后复用 `ExecutionRuntime`：
/// 日志、PID、停止/强杀、退出保护与端口探测都不需要另写一套。
///
/// 命令交给登录 zsh 执行，因此支持管道、`&&`、变量、别名与用户的 PATH
/// （例如 nvm / volta 安装的 node、npm）。这是用户显式输入的 shell 语法，
/// 与 Java 启动计划仍然保持 `Process.arguments` 数组传参（§27）是两回事。
public enum CommandLineLaunchPlanner {
    public static let shellExecutable = URL(fileURLWithPath: "/bin/zsh")

    public static func plan(
        settings: CommandLineSettings,
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ExecutableLaunchPlan {
        let command = settings.trimmedCommand
        guard !command.isEmpty else {
            throw IdeaLightRunError.invalidConfiguration(detail: "请先输入要执行的命令。")
        }

        let workingDirectory = try resolveWorkingDirectory(
            settings.workingDirectory,
            projectRoot: projectRoot
        )

        let parsedEnvironment = DotEnvParser.parse(settings.environmentText, environment: environment)
        if !parsedEnvironment.ignoredLineNumbers.isEmpty {
            let lines = parsedEnvironment.ignoredLineNumbers.map(String.init).joined(separator: "、")
            throw IdeaLightRunError.invalidConfiguration(
                detail: "环境变量第 \(lines) 行无法解析。请使用每行一条 KEY=VALUE（可加 export 前缀）。"
            )
        }

        var launchEnvironment = environment
        launchEnvironment.merge(parsedEnvironment.values) { _, newValue in newValue }

        return ExecutableLaunchPlan(
            executable: shellExecutable,
            // -i 让 .zshrc 里的 PATH / 别名生效；-l 读登录配置；-c 执行用户命令。
            // 命令始终是 args 数组里的一个元素，不经过字符串拼接。
            arguments: ["-ilc", command],
            environment: launchEnvironment,
            workingDirectory: workingDirectory,
            displayCommand: command
        )
    }

    /// 解析工作目录的公共入口，界面在运行前预览/校验时也能复用同一套规则。
    public static func resolveWorkingDirectory(_ rawPath: String, projectRoot: URL) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed.isEmpty {
            path = projectRoot.path
        } else {
            let expanded = trimmed
                .replacingOccurrences(of: "$PROJECT_DIR$", with: projectRoot.path)
                .replacingOccurrences(of: "${PROJECT_DIR}", with: projectRoot.path)
            path = (expanded as NSString).expandingTildeInPath
        }

        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : projectRoot.appendingPathComponent(path, isDirectory: true)
        let standardized = url.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IdeaLightRunError.invalidConfiguration(
                detail: "工作目录不存在或不是文件夹：\(standardized.path)。留空可使用项目根。"
            )
        }
        return standardized
    }
}
