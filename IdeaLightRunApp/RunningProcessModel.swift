import Foundation
import IdeaLightRunCore

/// GUI 侧的单次运行模型：包装 ProcessSession，回调统一切回主线程。
/// 日志经 LogRingBuffer（§37 上限）+ 100ms 批量（§103）进入 NSTextView 控制台。
@MainActor
final class RunningProcessModel: ObservableObject, Identifiable {
    nonisolated let id: String
    let configKey: String
    let configName: String
    let projectPath: String
    let logBuffer = LogRingBuffer()

    @Published var state: ProcessState = .preparing
    @Published var pid: Int32?
    @Published var lines: [LogLine] = []
    @Published var clearGeneration = 0

    var pendingRestart = false
    var onRestartNeeded: (() -> Void)?
    private(set) var session: ProcessSession?

    init(configKey: String, configName: String, projectPath: String) {
        self.configKey = configKey
        self.configName = configName
        self.projectPath = projectPath
        self.id = configKey
    }

    var isBuilding: Bool {
        switch state {
        case .preparing, .building, .resolvingClasspath, .starting:
            return true
        default:
            return false
        }
    }

    var isRunning: Bool { state == .running }

    func appendLog(_ line: LogLine) {
        lines.append(line)
    }

    func appendLog(_ batch: [LogLine]) {
        lines.append(contentsOf: batch)
    }

    func clearLogs() {
        logBuffer.clear()
        lines = []
        clearGeneration += 1
    }

    func setPipelineState(_ newState: ProcessState) {
        state = newState
    }

    func pipelineFailed(_ message: String) {
        appendLog(LogLine(stream: .system, text: "[IdeaLightRun] \(message)"))
        state = .failed(message)
    }

    /// 构建完成后挂接真实进程会话。
    func attach(session: ProcessSession) {
        self.session = session
        pid = session.pid
        session.onLogLines = { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.appendLog(batch)
            }
        }
        session.onState = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = newState
                switch newState {
                case .exited(let code):
                    self.pid = nil
                    self.appendLog(LogLine(stream: .system, text: "[IdeaLightRun] 进程退出，退出码 \(code)"))
                    if self.pendingRestart {
                        self.pendingRestart = false
                        self.onRestartNeeded?()
                    }
                case .failed(let message):
                    self.pid = nil
                    _ = message
                default:
                    break
                }
            }
        }
    }
}
