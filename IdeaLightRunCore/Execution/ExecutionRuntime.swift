import Foundation

/// 组合执行期间某个成员的事件。GUI 用它给每个成员维护独立的
/// 状态 / PID / 日志控制台；单进程运行时不会产生这类事件。
public struct CompoundMemberEvent: Sendable {
    public enum Kind: Sendable {
        case started(Int32)
        case state(ProcessState)
        case logLines([LogLine])
    }

    public var memberIndex: Int
    public var memberName: String
    public var configurationKey: String
    public var kind: Kind

    public init(memberIndex: Int, memberName: String, configurationKey: String, kind: Kind) {
        self.memberIndex = memberIndex
        self.memberName = memberName
        self.configurationKey = configurationKey
        self.kind = kind
    }
}

/// §4.2: Core 的统一执行器。GUI 与 CLI 只提交 `PreparedExecution`，
/// 不再各自创建 `ManagedProcessSession`、抢着处理终态或解释计划。
///
/// §Compound: 组合配置持有多个成员运行时——每个成员有独立的 PID、日志缓冲与状态。
/// 停止 / 强杀 / 等待退出按组传播；某个成员异常结束时先停掉其余成员，
/// 不让一次组合启动留下半套服务。
public final class ExecutionRuntime: @unchecked Sendable {
    public let configKey: String
    public let configName: String
    public let logBuffer: LogRingBuffer
    public let execution: PreparedExecution

    /// 组合配置的成员运行时（按 IDEA 配置顺序）；单进程为空。
    /// Compound 计划在准备阶段已展开嵌套，所以这里都是真正的进程执行器。
    public private(set) var members: [ExecutionRuntime] = []

    private let session: ManagedProcessSession?
    /// 测试配置的终态要按测试汇总修正（失败/没有匹配测试），
    /// 不能直接透传底层进程的退出码。
    private let testMonitor: TestOutcomeMonitor?
    private let testStateLock = NSLock()
    private var testStateOverride: ProcessState?
    private let handlerLock = NSLock()
    private var stateHandler: ((ProcessState) -> Void)?
    private var logHandler: (([LogLine]) -> Void)?
    private var startedHandler: ((Int32) -> Void)?
    private var compoundEventHandler: ((CompoundMemberEvent) -> Void)?

    private let compoundLock = NSLock()
    private var memberStates: [ProcessState] = []
    private var hasStarted = false
    private var lastPublishedState: ProcessState = .starting
    /// 用户主动停止（或已因失败开始清理）后，成员的 SIGTERM 退出码不再触发第二轮清理。
    private var stopRequested = false

    public init(
        configKey: String,
        configName: String,
        execution: PreparedExecution,
        logBuffer: LogRingBuffer = LogRingBuffer()
    ) throws {
        self.configKey = configKey
        self.configName = configName
        self.execution = execution
        self.logBuffer = logBuffer

        switch execution {
        case .process(let plan):
            self.testMonitor = nil
            self.session = try ManagedProcessSession(
                configKey: configKey,
                configName: configName,
                plan: plan,
                logBuffer: logBuffer
            )
        case .test(let plan):
            let monitor = TestOutcomeMonitor()
            self.testMonitor = monitor
            self.session = try ManagedProcessSession(
                configKey: configKey,
                configName: configName,
                plan: plan.process,
                logBuffer: logBuffer
            )
        case .compound(let plan):
            guard !plan.members.isEmpty else {
                throw IdeaLightRunError.invalidConfiguration(
                    detail: "Compound 配置 “\(plan.name)” 没有可启动的成员。"
                )
            }
            self.testMonitor = nil
            self.session = nil
            var runtimes: [ExecutionRuntime] = []
            runtimes.reserveCapacity(plan.members.count)
            for member in plan.members {
                runtimes.append(try ExecutionRuntime(
                    configKey: member.configurationKey,
                    configName: member.name,
                    execution: member.execution
                ))
            }
            self.members = runtimes
            self.memberStates = Array(repeating: .starting, count: runtimes.count)
            for (index, runtime) in runtimes.enumerated() {
                runtime.setHandlers(
                    onStarted: { [weak self] pid in self?.memberStarted(index: index, pid: pid) },
                    onState: { [weak self] state in self?.memberStateChanged(index: index, state: state) },
                    onLogLines: { [weak self] lines in self?.memberLogged(index: index, lines: lines) }
                )
            }
        }

        if let session {
            session.onState = { [weak self] state in self?.handleSessionState(state) }
            session.onLogLines = { [weak self] lines in
                self?.testMonitor?.consume(lines)
                self?.deliverLogs(lines)
            }
            session.onStarted = { [weak self] pid in self?.deliverStarted(pid) }
        }
    }

    /// 句柄必须在 `start()` 之前设置；回调可能来自后台线程，调用方负责线程切换。
    public func setHandlers(
        onStarted: ((Int32) -> Void)? = nil,
        onState: ((ProcessState) -> Void)? = nil,
        onLogLines: (([LogLine]) -> Void)? = nil,
        onCompoundMember: ((CompoundMemberEvent) -> Void)? = nil
    ) {
        handlerLock.lock()
        startedHandler = onStarted
        stateHandler = onState
        logHandler = onLogLines
        compoundEventHandler = onCompoundMember
        handlerLock.unlock()
    }

    public var state: ProcessState {
        testStateLock.lock()
        let override = testStateOverride
        testStateLock.unlock()
        if let override { return override }
        if let session { return session.state }
        compoundLock.lock()
        defer { compoundLock.unlock() }
        guard hasStarted else { return .starting }
        return Self.aggregateState(memberStates)
    }

    public var pid: Int32 {
        if let session { return session.pid }
        return members.first { $0.pid > 0 }?.pid ?? 0
    }

    public var isRunning: Bool {
        if let session { return session.isRunning }
        return !state.isTerminal
    }

    public func start() {
        if let session {
            session.start()
            return
        }
        compoundLock.lock()
        hasStarted = true
        compoundLock.unlock()

        emitSystemLog("启动 Compound 配置 “\(configName)”，共 \(members.count) 个成员…")
        for (index, member) in members.enumerated() {
            emitSystemLog("启动成员 \(index + 1)/\(members.count)：“\(member.configName)”…")
            // 前面的成员可能已经失败并请求停止；这里仍然 start()：
            // 子会话会登记 pending stop，进程跑起来后立刻终止，不会停在 .starting。
            member.start()
        }
    }

    public func stop() {
        // 先登记再终止：测试终态分类要区分“用户停止”和“测试失败”。
        compoundLock.lock()
        stopRequested = true
        compoundLock.unlock()
        if let session {
            session.stop()
            return
        }
        for member in members where !member.state.isTerminal {
            member.stop()
        }
    }

    public func forceKill() {
        compoundLock.lock()
        stopRequested = true
        compoundLock.unlock()
        if let session {
            session.forceKill()
            return
        }
        for member in members where !member.state.isTerminal {
            member.forceKill()
        }
    }

    @discardableResult
    public func waitUntilExit(timeout: TimeInterval) -> Bool {
        if let session {
            return session.waitUntilExit(timeout: timeout)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if members.allSatisfy({ $0.state.isTerminal }) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return members.allSatisfy { $0.state.isTerminal }
    }

    public func appendSystemLog(_ text: String) {
        if let session {
            session.appendSystemLog(text)
        } else {
            emitSystemLog(text)
        }
    }

    // MARK: - Compound 事件与状态

    private func memberStarted(index: Int, pid: Int32) {
        deliverMemberEvent(index: index, kind: .started(pid))
    }

    private func memberLogged(index: Int, lines: [LogLine]) {
        guard index < members.count else { return }
        let prefix = "[\(members[index].configName)] "
        // 组合根控制台拿到带成员前缀的合并日志；成员的独立控制台拿原始日志。
        let merged = lines.map { LogLine(stream: $0.stream, text: prefix + $0.text) }
        logBuffer.record(merged)
        deliverLogs(merged)
        deliverMemberEvent(index: index, kind: .logLines(lines))
    }

    private func memberStateChanged(index: Int, state: ProcessState) {
        let aggregate: ProcessState
        let changed: Bool
        let shouldCleanup: Bool
        compoundLock.lock()
        guard index < memberStates.count else {
            compoundLock.unlock()
            return
        }
        memberStates[index] = state
        aggregate = Self.aggregateState(memberStates)
        changed = aggregate != lastPublishedState
        lastPublishedState = aggregate
        // 不要求此刻已有其他成员进入运行态：失败可能发生在后续成员尚未 start
        // 之前（例如第一个成员立刻以非零码退出）。待启动成员收到 stop() 会登记
        // pending stop，start() 后立即终止，不会留下半套服务。
        shouldCleanup = !stopRequested && Self.isFailure(state)
        if shouldCleanup { stopRequested = true }
        compoundLock.unlock()

        deliverMemberEvent(index: index, kind: .state(state))
        if changed { deliverState(aggregate) }

        if shouldCleanup {
            let remaining = members.enumerated().filter { memberIndex, member in
                memberIndex != index && !member.state.isTerminal && member.state != .stopping
            }
            if !remaining.isEmpty {
                emitSystemLog("成员 “\(members[index].configName)” 已异常结束，正在停止其余成员…")
            }
            for (_, member) in remaining {
                member.stop()
            }
        }
        if changed, aggregate.isTerminal {
            emitSystemLog("Compound 配置已结束：\(aggregate.displayText)")
        }
    }

    private func emitSystemLog(_ text: String) {
        let line = LogLine(stream: .system, text: "[IdeaLightRun] \(text)")
        logBuffer.record([line])
        deliverLogs([line])
    }

    private static func isFailure(_ state: ProcessState) -> Bool {
        switch state {
        case .failed:
            return true
        case .exited(let code):
            return code != 0
        default:
            return false
        }
    }

    /// 所有成员都进入终态后才宣布组合的终态；还有成员在跑时保持运行/停止中，
    /// 否则 `waitUntilExit` / CLI 会在成员被清理前提前返回。
    static func aggregateState(_ states: [ProcessState]) -> ProcessState {
        guard !states.isEmpty else { return .starting }
        if states.contains(where: { $0.isActive }) {
            return states.contains(.stopping) ? .stopping : .running
        }
        if let failure = states.first(where: { state in
            if case .failed = state { return true }
            return false
        }) {
            return failure
        }
        if states.contains(.cancelled) { return .cancelled }
        let codes = states.compactMap { state -> Int32? in
            if case .exited(let code) = state { return code }
            return nil
        }
        if codes.count == states.count {
            return .exited(codes.first(where: { $0 != 0 }) ?? 0)
        }
        return .starting
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

    // MARK: - 测试终态

    /// 测试进程退出后，用日志里的测试汇总修正状态：
    /// - 有测试且失败 → 保留退出码（非 0）或显式 failed（退出码 0 但报告失败）
    /// - 一个测试都没跑 → failed，不能把“没找到测试”当成成功
    /// - 用户停止 → cancelled，不能报成测试失败
    private func handleSessionState(_ state: ProcessState) {
        guard let testMonitor, case .test(let plan) = execution else {
            deliverState(state)
            return
        }
        guard case .exited(let code) = state else {
            deliverState(state)
            return
        }

        compoundLock.lock()
        let cancelled = stopRequested
        compoundLock.unlock()
        if cancelled {
            emitSystemLog("测试已停止。")
            publishTestState(.cancelled)
            return
        }

        let summary = testMonitor.snapshot()
        if summary.didRunAnyTest {
            if summary.failedCount > 0 {
                emitSystemLog("测试失败：\(summary.detailText)（目标：\(plan.targetDescription)）。")
                publishTestState(code == 0 ? .failed("测试失败：\(summary.detailText)") : .exited(code))
            } else {
                emitSystemLog("测试完成：\(summary.detailText)（目标：\(plan.targetDescription)）。")
                publishTestState(.exited(code))
            }
            return
        }

        if summary.noTestsDetected || summary.hasReport {
            emitSystemLog("没有找到匹配的测试（目标：\(plan.targetDescription)）。")
            publishTestState(.failed("没有找到匹配的测试（目标：\(plan.targetDescription)）。"))
            return
        }

        if code != 0 {
            emitSystemLog("测试执行失败（退出码 \(code)），未取得测试汇总。")
            publishTestState(.failed("测试执行失败（退出码 \(code)），未取得测试汇总；请查看控制台输出。"))
        } else {
            emitSystemLog("测试进程已退出，但没有取得测试结果，无法确认测试是否运行。")
            publishTestState(.failed("没有取得测试结果，无法确认测试是否运行；请检查构建输出。"))
        }
    }

    private func publishTestState(_ state: ProcessState) {
        testStateLock.lock()
        testStateOverride = state
        testStateLock.unlock()
        deliverState(state)
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

    private func deliverMemberEvent(index: Int, kind: CompoundMemberEvent.Kind) {
        handlerLock.lock()
        let handler = compoundEventHandler
        handlerLock.unlock()
        guard let handler, index < members.count else { return }
        handler(CompoundMemberEvent(
            memberIndex: index,
            memberName: members[index].configName,
            configurationKey: members[index].configKey,
            kind: kind
        ))
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
