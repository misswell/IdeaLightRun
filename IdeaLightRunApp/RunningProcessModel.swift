import Foundation
import IdeaLightRunCore

/// Compound 成员的展示快照：每个成员有独立的状态 / PID / 端口。
struct CompoundMemberSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    var state: ProcessState
    var pid: Int32?
    var ports: [Int]
    var hotReload: HotReloadSnapshot? = nil
}

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
    /// Compound 成员快照；单进程配置为空。
    @Published private(set) var compoundMembers: [CompoundMemberSnapshot] = []
    /// 单进程配置的热更新状态；Compound 成员的状态在 `compoundMembers` 里。
    @Published private(set) var hotReload: HotReloadSnapshot?

    /// 构建期（classpath 解析/编译）进程句柄，Stop 用它终止 Maven。
    var buildHandle: ProcessHandle?

    var pendingRestart = false
    var onRestartNeeded: (() -> Void)?
    private(set) var runtime: ExecutionRuntime?
    private var portPollTask: Task<Void, Never>?
    private var memberConsoles: [String: LogViewModel] = [:]

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
        if !runtime.members.isEmpty {
            compoundMembers = runtime.members.map {
                CompoundMemberSnapshot(id: $0.configKey, name: $0.configName, state: $0.state, pid: nil, ports: [])
            }
            for member in runtime.members where memberConsoles[member.configKey] == nil {
                memberConsoles[member.configKey] = LogViewModel()
            }
        }
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
            },
            onCompoundMember: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.applyCompoundEvent(event)
                }
            },
            onHotReload: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.hotReload = snapshot
                    self.onChange?()
                }
            },
            onHotReloadRestart: { [weak self] reason in
                // 自动重启复用现有“停止 → 等旧进程退出 → 重新走完整流水线”的链路；
                // 返回 true 表示这次请求已被接管。
                Task { @MainActor [weak self] in
                    guard let self, let runtime = self.runtime else { return }
                    self.appendLog(LogLine(
                        stream: .system,
                        text: "[IdeaLightRun] 热更新需要重启：\(reason)；正在等待旧进程退出后重新启动。"
                    ))
                    self.pendingRestart = true
                    runtime.stop()
                }
                return true
            }
        )
    }

    /// 单进程的“立即编译并热更新”；Compound 传成员 id。
    func requestHotReload(memberID: String? = nil) {
        if let memberID,
           let index = compoundMembers.firstIndex(where: { $0.id == memberID }) {
            runtime?.members[index].requestHotReload()
        } else {
            runtime?.requestHotReload()
        }
    }

    /// “需要重启”提示里的“暂不重启”。
    func dismissHotReloadRestartPrompt(memberID: String? = nil) {
        if let memberID,
           let index = compoundMembers.firstIndex(where: { $0.id == memberID }) {
            runtime?.members[index].dismissHotReloadRestartPrompt()
        } else {
            runtime?.dismissHotReloadRestartPrompt()
        }
    }

    /// 成员控制台：Compound 每个成员一份独立日志缓冲。
    func consoleModel(for memberID: String) -> LogViewModel? {
        memberConsoles[memberID]
    }

    private func applyCompoundEvent(_ event: CompoundMemberEvent) {
        guard let index = compoundMembers.firstIndex(where: { $0.id == event.configurationKey }) else { return }
        switch event.kind {
        case .started(let newPID):
            compoundMembers[index].pid = newPID
            onChange?()
        case .state(let newState):
            compoundMembers[index].state = newState
            switch newState {
            case .exited(let code):
                compoundMembers[index].pid = nil
                compoundMembers[index].ports = []
                memberConsoles[event.configurationKey]?.appendLog(
                    LogLine(stream: .system, text: "[IdeaLightRun] 进程退出，退出码 \(code)")
                )
                appendLog(LogLine(
                    stream: .system,
                    text: "[IdeaLightRun] 成员 “\(event.memberName)” 退出，退出码 \(code)"
                ))
            case .failed(let detail):
                compoundMembers[index].pid = nil
                compoundMembers[index].ports = []
                memberConsoles[event.configurationKey]?.appendLog(
                    LogLine(stream: .system, text: "[IdeaLightRun] 启动/运行失败：\(detail)")
                )
                appendLog(LogLine(
                    stream: .system,
                    text: "[IdeaLightRun] 成员 “\(event.memberName)” 失败：\(detail)"
                ))
            case .cancelled:
                compoundMembers[index].pid = nil
                compoundMembers[index].ports = []
            default:
                break
            }
            onChange?()
        case .logLines(let lines):
            memberConsoles[event.configurationKey]?.appendLog(lines)
        case .hotReload(let snapshot):
            compoundMembers[index].hotReload = snapshot
            onChange?()
        case .hotReloadRestartRequested(let reason):
            let text = "[IdeaLightRun] 热更新需要重启：\(reason)"
            memberConsoles[event.configurationKey]?.appendLog(LogLine(stream: .system, text: text))
            appendLog(LogLine(stream: .system, text: text + "（Compound 成员请手动重启整个组合）"))
            onChange?()
        }
    }

    /// 探测「启动了哪些端口」：Spring Boot 之类要几秒才 bind，轮询到进程终态为止。
    /// 只读本机 lsof（§64 不涉网），端口集合变化时发布并在控制台补一条系统消息。
    /// Compound 对每个成员分别探测，端口不会串到别的成员身上。
    private func startPortPolling() {
        portPollTask?.cancel()
        portPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state.isTerminal { return }
                if !self.compoundMembers.isEmpty {
                    var changed = false
                    for index in self.compoundMembers.indices {
                        guard let memberPID = self.compoundMembers[index].pid else { continue }
                        let ports = await Task.detached(priority: .utility) {
                            ListeningPortScanner.listeningPorts(pid: memberPID)
                        }.value
                        guard !Task.isCancelled, !self.state.isTerminal else { return }
                        if ports != self.compoundMembers[index].ports {
                            self.compoundMembers[index].ports = ports
                            changed = true
                            if !ports.isEmpty {
                                let text = ports.map(String.init).joined(separator: "、")
                                self.memberConsoles[self.compoundMembers[index].id]?.appendLog(
                                    LogLine(stream: .system, text: "[IdeaLightRun] 正在监听端口: \(text)")
                                )
                            }
                        }
                    }
                    if changed { self.onChange?() }
                } else if let pid = self.pid {
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
