import Foundation
import IdeaLightRunCore

/// GUI 侧的单次运行模型：包装 ManagedProcessSession，回调统一切回主线程。
/// 日志经 LogRingBuffer（§37 上限）+ 100ms 批量（§103）进入 NSTextView 控制台。
@MainActor
final class RunningProcessModel: LogViewModel, Identifiable {
    nonisolated let id: String
    let configKey: String
    let configName: String
    let projectPath: String
    let logBuffer = LogRingBuffer()

    @Published private(set) var state: ProcessState = .preparing
    @Published private(set) var pid: Int32?

    /// 构建期（classpath 解析/编译）进程句柄，Stop 用它终止 Maven。
    var buildHandle: ProcessHandle?

    var pendingRestart = false
    var onRestartNeeded: (() -> Void)?
    private(set) var session: ManagedProcessSession?

    /// 状态/PID 变更通知。本模型是 AppStore 里的嵌套 ObservableObject，SwiftUI 不会自动
    /// 观察它；不显式冒泡到 AppStore.objectWillChange，列表行状态、顶栏按钮和运行横幅会
    /// 永远冻结在 Run 那一刻的快照上（进程已退出仍显示"准备中"）。
    var onChange: (() -> Void)?

    init(configKey: String, configName: String, projectPath: String) {
        self.configKey = configKey
        self.configName = configName
        self.projectPath = projectPath
        self.id = configKey
        super.init()
    }

    var isBuilding: Bool {
        switch state {
        case .preparing, .building, .resolvingClasspath, .starting:
            return true
        default:
            return false
        }
    }

    var isActiveBuildPhase: Bool { isBuilding }

    var isRunning: Bool { state == .running }

    override func clearLogs() {
        logBuffer.clear()
        super.clearLogs()
    }

    func setPipelineState(_ newState: ProcessState) {
        publish(newState)
    }

    func pipelineFailed(_ message: String) {
        appendLog(LogLine(stream: .system, text: "[IdeaLightRun] \(message)"))
        publish(.failed(message))
    }

    /// 构建完成后挂接真实进程会话。
    func attach(session: ManagedProcessSession) {
        self.session = session
        setPID(session.pid)
        session.onLogLines = { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.appendLog(batch)
            }
        }
        session.onState = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publish(newState)
                switch newState {
                case .exited(let code):
                    self.setPID(nil)
                    self.appendLog(LogLine(stream: .system, text: "[IdeaLightRun] 进程退出，退出码 \(code)"))
                    if self.pendingRestart {
                        self.pendingRestart = false
                        self.onRestartNeeded?()
                    }
                case .failed:
                    // 失败原因由 ManagedProcessSession 写入 logBuffer 后随批次送达，此处不重复。
                    self.setPID(nil)
                default:
                    break
                }
            }
        }
    }

    private func publish(_ newState: ProcessState) {
        state = newState
        onChange?()
    }

    private func setPID(_ newPID: Int32?) {
        pid = newPID
        onChange?()
    }
}
