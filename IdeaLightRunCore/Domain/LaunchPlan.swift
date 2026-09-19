import Foundation

/// §26: 所有解析完成后的启动计划。UI 不直接拼 Java 命令。
public struct JavaLaunchPlan: Sendable {
    public var javaExecutable: URL
    public var vmArguments: [String]
    /// §27: classpath 以 ":" 连接后通过 -cp 传递（@argfile 支持在 P1，§112）。
    public var classpath: [String]
    public var mainClass: String
    public var programArguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL

    public init(
        javaExecutable: URL,
        vmArguments: [String],
        classpath: [String],
        mainClass: String,
        programArguments: [String],
        environment: [String: String],
        workingDirectory: URL
    ) {
        self.javaExecutable = javaExecutable
        self.vmArguments = vmArguments
        self.classpath = classpath
        self.mainClass = mainClass
        self.programArguments = programArguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// 用于"复制启动命令"等展示场景；不用于执行。
    public func displayCommand() -> String {
        var parts: [String] = [javaExecutable.path]
        parts.append(contentsOf: vmArguments)
        parts.append(contentsOf: ["-cp", classpath.joined(separator: ":"), mainClass])
        parts.append(contentsOf: programArguments)
        return parts
            .map { $0.contains(" ") ? "\"" + $0 + "\"" : $0 }
            .joined(separator: " ")
    }
}

/// §32: 进程状态机。
public enum ProcessState: Equatable, Sendable {
    case preparing
    case building
    case resolvingClasspath
    case starting
    case running
    case stopping
    case exited(Int32)
    case cancelled
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .exited, .failed, .cancelled: return true
        default: return false
        }
    }

    /// 运行会话活跃（构建期 + 运行期）——Stop 按钮的可用条件。
    public var isActive: Bool {
        switch self {
        case .preparing, .building, .resolvingClasspath, .starting, .running, .stopping:
            return true
        case .exited, .cancelled, .failed:
            return false
        }
    }

    public var displayText: String {
        switch self {
        case .preparing: return "准备中"
        case .building: return "编译中"
        case .resolvingClasspath: return "解析依赖中"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .exited(let code): return "已退出 (\(code))"
        case .cancelled: return "已停止"
        case .failed: return "失败"
        }
    }
}

public enum LogStream: String, Codable, Sendable {
    case stdout
    case stderr
    case system
}

public struct LogLine: Sendable {
    public var timestamp: Date
    public var stream: LogStream
    public var text: String

    public init(timestamp: Date = Date(), stream: LogStream, text: String) {
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
    }
}

public typealias LogCallback = (LogLine) -> Void
