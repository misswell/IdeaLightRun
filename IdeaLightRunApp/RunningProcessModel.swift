import Foundation
import IdeaLightRunCore

/// GUI 侧的单次运行模型：包装 Core 的 ExecutionRuntime，回调统一切回主线程。
/// 日志经 LogRingBuffer（§37 上限）+ 100ms 批量（§103）进入 NSTextView 控制台。
/// 一个模型对应一个运行实例（RunSessionID），同一配置可并行多个实例（allowParallelRun）。
@MainActor
final class RunningProcessModel: LogViewModel, Identifiable {
    nonisolated let id: String
    /// 本实例的身份：项目 + 配置 + 实例 UUID（§P0-1）。
    let sessionID: RunSessionID
    var configKey: String { sessionID.configurationID }
    var projectPath: String { sessionID.projectID }
    let configName: String
    /// 实例启动时刻；多实例列表按它倒序展示。
    let startedAt = Date()
    let logBuffer = LogRingBuffer()

    @Published private(set) var state: ProcessState = .preparing
    /// 进程真正 run() 成功后才有的 PID（onStarted 回调写入，§P0-2）。
    @Published private(set) var pid: Int32?
    /// 进程正在 LISTEN 的 TCP 端口（本机 lsof 探测，仅进程存活期间轮询）。
    @Published private(set) var listeningPorts: [Int] = []

    /// 构建期（classpath 解析/编译）进程句柄，Stop 用它终止 Maven。
    var buildHandle: ProcessHandle?

    var pendingRestart = false
    var onRestartNeeded: (() -> Void)?
    private(set) var runtime: ExecutionRuntime?
    private var portPollTask: Task<Void, Never>?

    /// 状态/PID 变更通知。本模型是 AppStore 里的嵌套 ObservableObject，SwiftUI 不会自动
    /// 观察它；不显式冒泡到 AppStore.objectWillChange，列表行状态、顶栏按钮和运行横幅会
    /// 永远冻结在 Run 那一刻的快照上（进程已退出仍显示"准备中"）。
    var onChange: (() -> Void)?

    init(sessionID: RunSessionID, configName: String) {
        self.sessionID = sessionID
        self.configName = configName
        self.id = sessionID.instanceID.uuidString
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

    /// 构建完成后挂接统一执行器。
    /// PID 不在这里读取：会话在 onStarted（run() 成功）后才发布 PID（§P0-2）。
    func attach(runtime: ExecutionRuntime) {
        self.runtime = runtime
        startPortPolling()
        runtime.setHandlers(
            onStarted: { [weak self] newPID in
                Task { @MainActor [weak self] in
                    self?.setPID(newPID)
                }
            },
            onState: { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.publish(newState)
                    switch newState {
                    case .exited(let code):
                        self.setPID(nil)
                        self.listeningPorts = []
                        self.appendLog(LogLine(stream: .system, text: "[IdeaLightRun] 进程退出，退出码 \(code)"))
                        if self.pendingRestart {
                            self.pendingRestart = false
                            self.onRestartNeeded?()
                        }
                    case .failed:
                        // 失败原因由底层会话写入 logBuffer 后随批次送达，此处不重复。
                        self.setPID(nil)
                        self.listeningPorts = []
                    default:
                        break
                    }
                }
            },
            onLogLines: { [weak self] batch in
                Task { @MainActor [weak self] in
                    self?.appendLog(batch)
                }
            }
        )
    }

    /// 探测「启动了哪些端口」：Spring Boot 之类要几秒才 bind，轮询到进程终态为止。
    /// 只读本机 lsof（§64 不涉网），端口集合变化时发布并在控制台补一条系统消息。
    private func startPortPolling() {
        portPollTask?.cancel()
        portPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state.isTerminal { return }
                if let pid = self.pid {
                    let ports = await Task.detached(priority: .utility) {
                        ListeningPortScanner.listeningPorts(pid: pid)
                    }.value
                    guard !Task.isCancelled, !self.state.isTerminal else { return }
                    if ports != self.listeningPorts {
                        self.listeningPorts = ports
                        self.onChange?()
                        if !ports.isEmpty {
                            let text = ports.map(String.init).joined(separator: "、")
                            self.appendLog(LogLine(stream: .system, text: "[IdeaLightRun] 正在监听端口: \(text)"))
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(3))
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
