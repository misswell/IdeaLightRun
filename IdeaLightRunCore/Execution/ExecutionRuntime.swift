import Foundation

/// §4.2: Core 的统一执行器。GUI 与 CLI 只提交 `PreparedExecution`，
/// 不再各自创建 `ManagedProcessSession`、抢着处理终态或解释计划。
///
/// M2 覆盖单个进程；Compound 的统一调度在 M3 由组合执行器接管。
public final class ExecutionRuntime: @unchecked Sendable {
    public let configKey: String
    public let configName: String
    public let logBuffer: LogRingBuffer
    public let execution: PreparedExecution

    private let session: ManagedProcessSession
    private let handlerLock = NSLock()
    private var stateHandler: ((ProcessState) -> Void)?
    private var logHandler: (([LogLine]) -> Void)?
    private var startedHandler: ((Int32) -> Void)?

    public init(
        configKey: String,
        configName: String,
        execution: PreparedExecution,
        logBuffer: LogRingBuffer = LogRingBuffer()
    ) throws {
        let plan: ExecutableLaunchPlan
        switch execution {
        case .process(let processPlan):
            plan = processPlan
        case .compound:
            throw IdeaLightRunError.unsupportedConfiguration(
                detail: "Compound 多配置执行将在 Milestone 3 接入，当前不能启动。"
            )
        }

        self.configKey = configKey
        self.configName = configName
        self.execution = execution
        self.logBuffer = logBuffer

        let session = try ManagedProcessSession(
            configKey: configKey,
            configName: configName,
            plan: plan,
            logBuffer: logBuffer
        )
        self.session = session
        session.onState = { [weak self] state in self?.deliverState(state) }
        session.onLogLines = { [weak self] lines in self?.deliverLogs(lines) }
        session.onStarted = { [weak self] pid in self?.deliverStarted(pid) }
    }

    /// 句柄必须在 `start()` 之前设置；回调可能来自后台线程，调用方负责线程切换。
    public func setHandlers(
        onStarted: ((Int32) -> Void)? = nil,
        onState: ((ProcessState) -> Void)? = nil,
        onLogLines: (([LogLine]) -> Void)? = nil
    ) {
        handlerLock.lock()
        startedHandler = onStarted
        stateHandler = onState
        logHandler = onLogLines
        handlerLock.unlock()
    }

    public var state: ProcessState { session.state }
    public var pid: Int32 { session.pid }
    public var isRunning: Bool { session.isRunning }

    public func start() { session.start() }
    public func stop() { session.stop() }
    public func forceKill() { session.forceKill() }

    @discardableResult
    public func waitUntilExit(timeout: TimeInterval) -> Bool {
        session.waitUntilExit(timeout: timeout)
    }

    public func appendSystemLog(_ text: String) {
        session.appendSystemLog(text)
    }

    // MARK: - Before Launch 的同步执行

    /// 被引用的运行配置要像 IDEA 那样先跑完再回来：
    /// 输出并进当前会话的日志、等它退出；退出码非 0 时中止本次启动。
    public static func runUntilExit(
        execution: PreparedExecution,
        configName: String,
        processHandle: ProcessHandle?,
        log: @escaping LogCallback
    ) async throws {
        let runtime = try ExecutionRuntime(
            configKey: "before-launch::\(configName)",
            configName: configName,
            execution: execution
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let sink = RuntimeResumeSink(continuation)
            runtime.setHandlers(
                onState: { state in
                    // 外层 Stop 先置取消标记再终止进程：SIGTERM 的退出码不能当成构建失败。
                    let outcome = Self.outcome(
                        for: state,
                        configName: configName,
                        cancelled: processHandle?.isCancelled == true
                    )
                    if let outcome {
                        sink.resume(with: outcome)
                    }
                },
                onLogLines: { lines in lines.forEach(log) }
            )
            runtime.start()
            // Stop 落在嵌套进程上：外层只有构建句柄，这里代为转达，
            // SIGTERM 后仍不退出就强杀，避免被引用的进程把本次启动永久挂住。
            Task.detached(priority: .userInitiated) {
                while !runtime.state.isTerminal {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if processHandle?.isCancelled == true {
                        runtime.stop()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if !runtime.state.isTerminal { runtime.forceKill() }
                        return
                    }
                }
            }
        }
    }

    static func outcome(
        for state: ProcessState,
        configName: String,
        cancelled: Bool = false
    ) -> Result<Void, Error>? {
        switch state {
        case .exited(let code):
            if cancelled {
                return .failure(IdeaLightRunError.launchCancelled(
                    detail: "Before Launch 引用的配置 “\(configName)” 已被用户停止。"
                ))
            }
            guard code != 0 else { return .success(()) }
            return .failure(IdeaLightRunError.buildFailed(
                detail: "Before Launch 引用的配置 “\(configName)” 以退出码 \(code) 结束，本次启动已中止。"
            ))
        case .failed(let detail):
            return .failure(IdeaLightRunError.launchFailed(
                detail: "Before Launch 引用的配置 “\(configName)” 未能正常运行：\(detail)"
            ))
        case .cancelled:
            return .failure(IdeaLightRunError.launchCancelled(
                detail: "Before Launch 引用的配置 “\(configName)” 已被用户停止。"
            ))
        default:
            return nil
        }
    }

    // MARK: - 回调转发

    private func deliverState(_ state: ProcessState) {
        handlerLock.lock()
        let handler = stateHandler
        handlerLock.unlock()
        handler?(state)
    }

    private func deliverLogs(_ lines: [LogLine]) {
        handlerLock.lock()
        let handler = logHandler
        handlerLock.unlock()
        handler?(lines)
    }

    private func deliverStarted(_ pid: Int32) {
        handlerLock.lock()
        let handler = startedHandler
        handlerLock.unlock()
        handler?(pid)
    }
}

/// continuation 只能 resume 一次：终态路径（退出码 / 失败 / 取消）交错时
/// 重复 resume 会直接崩溃，这里显式去重。
private final class RuntimeResumeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
