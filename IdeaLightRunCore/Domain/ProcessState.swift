import Foundation

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
