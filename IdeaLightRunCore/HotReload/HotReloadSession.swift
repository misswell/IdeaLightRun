import Foundation

/// 一个运行中 JVM 的热更新会话。
///
/// 数据流：FSEvents 信号 → 去抖 → 全量指纹快照/差异 → BuildGate 内增量编译
/// → 输出 class 差异 → 内置 Agent 逐类 redefine。外部构建只走“输出差异”这一段。
///
/// 线程模型：公开方法可从任意线程调用；会话内部用锁保护状态，重的快照/编译/网络
/// 工作都在后台 Task 中执行。`stop()` 不等待控制通道超时，先关 socket 再收尾。
public final class HotReloadSession: @unchecked Sendable {
    public let plan: HotReloadLaunchPlan

    private let log: @Sendable (String) -> Void
    private let onSnapshot: @Sendable (HotReloadSnapshot) -> Void
    /// 返回 false 表示宿主当前无法重启（例如没有重启入口），会话必须降级为「需要重启」。
    private let onRestartRequested: (@Sendable (String) -> Bool)?

    private let lock = NSLock()
    private var state: HotReloadState = .listening
    private var detail = "正在准备热更新…"
    private var summary: HotReloadSummary?
    private var awaitingRestart = false
    private var pendingRestartReason: String?
    private var stopped = false
    private var started = false
    private var backendReady = false
    private var isProcessing = false
    private var pendingCycle = false
    private var manualRequested = false
    private var restartRequested = false
    private var baseline: HotReloadWorkspaceSnapshot?
    private var truncatedLogged = false
    private var pendingCompileTargets: [String: BuildTarget] = [:]

    private var agentClient: HotReloadAgentClient?
    private var watcher: HotReloadFileWatcher?
    private var startTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var compileHandle: ProcessHandle?

    public init(
        plan: HotReloadLaunchPlan,
        log: @escaping @Sendable (String) -> Void,
        onSnapshot: @escaping @Sendable (HotReloadSnapshot) -> Void,
        onRestartRequested: (@Sendable (String) -> Bool)? = nil
    ) {
        self.plan = plan
        self.log = log
        self.onSnapshot = onSnapshot
        self.onRestartRequested = onRestartRequested
    }

    public var currentSnapshot: HotReloadSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    // MARK: - 生命周期

    public func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        publish(.listening, detail: "正在准备热更新…")
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.startInternal()
        }
        lock.lock()
        startTask = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let watcher = self.watcher
        self.watcher = nil
        let client = agentClient
        agentClient = nil
        let handle = compileHandle
        compileHandle = nil
        let debounce = debounceTask
        debounceTask = nil
        let start = startTask
        startTask = nil
        lock.unlock()

        watcher?.stop()
        handle?.terminate()
        client?.shutdown()
        debounce?.cancel()
        start?.cancel()
        plan.agentLaunch?.cleanup()

        lock.lock()
        state = .stopped
        detail = "热更新已停止。"
        awaitingRestart = false
        let snapshot = makeSnapshotLocked()
        lock.unlock()
        onSnapshot(snapshot)
    }

    /// 界面上的“立即编译并热更新”。自动编译关闭时也走这里。
    public func requestManualReload() {
        lock.lock()
        guard !stopped, backendReady || plan.delegatesApply else {
            lock.unlock()
            return
        }
        manualRequested = true
        let busy = isProcessing
        lock.unlock()
        if !busy {
            publish(.compiling, detail: "正在检查并处理变更…")
        }
        scheduleCycle(after: 0, manual: true)
    }

    /// 用户在“需要重启”提示里选择暂不重启：只清除等待确认标记，
    /// 状态仍保留为 `requiresRestart`，不伪造“已恢复”。
    public func dismissRestartPrompt() {
        lock.lock()
        guard !stopped, awaitingRestart else {
            lock.unlock()
            return
        }
        awaitingRestart = false
        if let reason = pendingRestartReason {
            detail = "需要重启：\(reason) 已选择暂不重启，可稍后手动重启。"
        }
        let snapshot = makeSnapshotLocked()
        lock.unlock()
        onSnapshot(snapshot)
    }

    private func startInternal() async {
        for note in plan.notes {
            log("[HotReload] \(note)")
        }

        if let problem = plan.agentInitProblem {
            publish(.agentUnavailable, detail: problem)
            log("[HotReload] 热更新不可用：\(problem)")
            return
        }

        if plan.provider == .standard {
            guard let agentLaunch = plan.agentLaunch else {
                publish(.agentUnavailable, detail: "内置 Agent 未准备好。")
                return
            }
            do {
                let port = try HotReloadAgentEndpoint.waitForPort(
                    portFile: agentLaunch.portFileURL,
                    timeout: 20,
                    isCancelled: { self.isStopped }
                )
                let client = try HotReloadAgentClient(port: port, token: agentLaunch.token)
                let status = try client.status()
                guard status.status == .ok else {
                    throw IdeaLightRunError.hotReloadUnavailable(
                        detail: "内置 Agent 初始化失败：\(status.message)"
                    )
                }
                lock.lock()
                if stopped {
                    lock.unlock()
                    client.shutdown()
                    return
                }
                agentClient = client
                backendReady = true
                lock.unlock()
                log("[HotReload] 内置 Agent 已连接（127.0.0.1:\(port)）：\(status.message)")
            } catch {
                if isStopped { return }
                let message = (error as? IdeaLightRunError)?.localizedDescription
                    ?? error.localizedDescription
                publish(.agentUnavailable, detail: message)
                log("[HotReload] 内置 Agent 初始化失败：\(message)")
                return
            }
        } else {
            lock.lock()
            backendReady = true
            lock.unlock()
        }

        let baseline = plan.workspace.snapshot()
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        self.baseline = baseline
        lock.unlock()
        if baseline.truncated {
            log("[HotReload] 警告：监听文件数超过上限，部分变更可能不会被发现。")
            lock.lock()
            truncatedLogged = true
            lock.unlock()
        }

        if plan.configuration.hasAnyWatcher {
            let watcher = HotReloadFileWatcher(
                roots: [plan.workspace.projectRoot],
                isRelevant: { [workspace = plan.workspace] path in
                    workspace.isRelevantPath(path)
                },
                onEvents: { [weak self] _ in
                    self?.fileEventsReceived()
                }
            )
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            self.watcher = watcher
            lock.unlock()
            watcher.start()
            log("[HotReload] 监听 \(plan.workspace.moduleWatches.count) 个模块的源码与 \(plan.workspace.outputRoots.count) 个输出目录（去抖 \(Int(plan.configuration.effectiveDebounce * 1000)) ms）。")
        } else {
            log("[HotReload] 文件监听已关闭；只响应“立即编译并热更新”。")
        }

        publish(.listening, detail: readyDetail())
    }

    private func readyDetail() -> String {
        let provider = plan.provider.displayName
        if plan.delegatesApply {
            return "监听中；编译后由 \(provider) 自行热更新 / 快速重启，IdeaLightRun 不宣称类已被替换。"
        }
        return "监听中；保存源码或外部构建产出 class 后自动处理。"
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: - 事件与去抖

    private func fileEventsReceived() {
        scheduleCycle(after: plan.configuration.effectiveDebounce, manual: false)
    }

    private func scheduleCycle(after delay: TimeInterval, manual: Bool) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        if manual { manualRequested = true }
        if isProcessing {
            pendingCycle = true
            lock.unlock()
            return
        }
        debounceTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.runCycle()
        }
        debounceTask = task
        lock.unlock()
    }

    private func runCycle() async {
        lock.lock()
        guard !stopped, !isProcessing, let previous = baseline else {
            if isProcessing { pendingCycle = true }
            lock.unlock()
            return
        }
        isProcessing = true
        let manual = manualRequested
        manualRequested = false
        let pendingTargets = manual ? Array(pendingCompileTargets.values) : []
        lock.unlock()

        await processCycle(previous: previous, manual: manual, pendingTargets: pendingTargets)

        lock.lock()
        isProcessing = false
        let pending = pendingCycle
        pendingCycle = false
        let stillStopped = stopped
        lock.unlock()
        if !stillStopped && pending {
            scheduleCycle(after: 0.15, manual: false)
        }
    }

    private func processCycle(
        previous: HotReloadWorkspaceSnapshot,
        manual: Bool,
        pendingTargets: [BuildTarget]
    ) async {
        let startedAt = Date()
        let current = plan.workspace.snapshot(reusing: previous)
        if isStopped { return }

        var diff = current.diff(from: previous)
        if !plan.configuration.watchResources {
            diff.changedSourceResources = []
            diff.removedSourceResources = []
            diff.changedOutputResources = []
            diff.removedOutputResources = []
        }

        if current.truncated {
            logOnceTruncation()
        }

        let hasSourceWork = diff.hasSourceChanges || diff.hasSourceResourceChanges
        if diff.isEmpty && pendingTargets.isEmpty {
            setBaseline(current)
            if manual {
                publish(.listening, detail: "没有检测到需要处理的变更。")
            }
            return
        }

        // 只监听源码（关闭输出监听）时，外部构建的 class 变化不应触发动作。
        if !hasSourceWork && pendingTargets.isEmpty && !plan.configuration.watchCompiledOutputs && !manual {
            setBaseline(current)
            return
        }

        if hasSourceWork && !plan.configuration.autoCompileOnChange && !manual {
            let targets = compileTargets(in: diff)
            if !targets.isEmpty {
                lock.lock()
                for target in targets {
                    pendingCompileTargets[target.module.id] = target
                }
                lock.unlock()
            }
            setBaseline(current)
            let summary = makeSummary(
                diff: diff,
                compiledModules: [],
                didCompile: false,
                startedAt: startedAt
            )
            publish(
                .attention,
                detail: "检测到 \(diff.changedSources.count + diff.removedSources.count) 个源码文件变更；"
                    + "自动编译已关闭。点击“立即编译并热更新”执行编译。",
                summary: summary
            )
            log("[HotReload] 检测到源码变更，自动编译已关闭；等待手动触发。")
            return
        }

        var compileTargets: [BuildTarget] = pendingTargets
        let newlyChanged = self.compileTargets(in: diff)
        for target in newlyChanged where !compileTargets.contains(where: { $0.module.id == target.module.id }) {
            compileTargets.append(target)
        }

        if compileTargets.isEmpty {
            // 只有外部构建产出的 class / 资源发生变化。
            setBaseline(current)
            var summary = makeSummary(
                diff: diff,
                compiledModules: [],
                didCompile: false,
                startedAt: startedAt
            )
            applyAndPublish(diff: diff, summary: &summary)
            return
        }

        let moduleNames = compileTargets.map(\.module.name)
        publish(.compiling, detail: "正在编译 \(moduleNames.joined(separator: "、"))…")
        log("[HotReload] 检测到变更，开始编译 \(moduleNames.joined(separator: "、"))…")
        if !diff.changedSources.isEmpty {
            let examples = diff.sourceChanges(projectRoot: plan.workspace.projectRoot).prefix(5)
            log("[HotReload] 源文件变更：\(examples.joined(separator: "、"))"
                + (diff.changedSources.count > 5 ? " 等 \(diff.changedSources.count) 个" : ""))
        }

        let handle = ProcessHandle()
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        compileHandle = handle
        lock.unlock()

        let compileError: Error?
        let session = self
        let compilePlan = plan
        let compileLog = log
        let targets = compileTargets
        do {
            try await BuildGate.shared.run(projectKey: compilePlan.projectKey) { [compilePlan, handle, compileLog, session, targets] in
                for target in targets {
                    // 等 BuildGate 期间用户可能已经停止；拿到锁后不得再编译。
                    guard !session.isStopped else {
                        throw IdeaLightRunError.launchCancelled(detail: "热更新已停止。")
                    }
                    try compilePlan.adapter.buildModule(target, handle: handle, log: { line in
                        compileLog(line.text)
                    })
                }
            }
            compileError = nil
        } catch {
            compileError = error
        }

        lock.lock()
        compileHandle = nil
        let stoppedAfterCompile = stopped
        lock.unlock()
        if stoppedAfterCompile { return }

        let post = plan.workspace.snapshot(reusing: current)

        if let compileError {
            if case IdeaLightRunError.launchCancelled = compileError {
                if isStopped { return }
            }
            let preserved = mergeBaseline(pre: current, post: post, previous: previous)
            setBaseline(preserved.snapshot)
            if preserved.hasSourceChangesDuringWork {
                signalPendingCycle()
            }
            var summary = makeSummary(
                diff: diff,
                compiledModules: moduleNames,
                didCompile: false,
                startedAt: startedAt
            )
            let message = (compileError as? IdeaLightRunError)?.localizedDescription
                ?? compileError.localizedDescription
            summary.notes.append("编译失败，未应用任何部分产物。")
            publish(.compileFailed, detail: message, summary: summary)
            log("[HotReload] 编译失败：\(message)")
            return
        }

        let preserved = mergeBaseline(pre: current, post: post, previous: previous)
        setBaseline(preserved.snapshot)
        if preserved.hasSourceChangesDuringWork {
            signalPendingCycle()
        }
        lock.lock()
        for target in compileTargets {
            pendingCompileTargets.removeValue(forKey: target.module.id)
        }
        lock.unlock()

        let overall = post.diff(from: previous)
        var summary = makeSummary(
            diff: overall,
            compiledModules: Array(Set(moduleNames)).sorted(),
            didCompile: true,
            startedAt: startedAt
        )
        if preserved.hasSourceChangesDuringWork {
            summary.notes.append("编译期间源码再次发生变化，已排队处理最新变更。")
        }
        applyAndPublish(diff: overall, summary: &summary)
    }

    private func signalPendingCycle() {
        lock.lock()
        pendingCycle = true
        lock.unlock()
    }

    private func setBaseline(_ snapshot: HotReloadWorkspaceSnapshot) {
        lock.lock()
        baseline = snapshot
        lock.unlock()
    }

    private struct PreservedBaseline {
        var snapshot: HotReloadWorkspaceSnapshot
        var hasSourceChangesDuringWork: Bool
    }

    /// 编译期间被再次修改的源码必须保留旧指纹，否则这次修改会被吞掉；
    /// 输出目录则整体前移，避免下一轮把半套 class 当成外部构建产物。
    private func mergeBaseline(
        pre: HotReloadWorkspaceSnapshot,
        post: HotReloadWorkspaceSnapshot,
        previous: HotReloadWorkspaceSnapshot
    ) -> PreservedBaseline {
        var result = post
        var changedDuringWork = false

        for (path, old) in previous.sources {
            let preState = pre.sources[path]
            let postState = post.sources[path]
            if preState?.fingerprint != postState?.fingerprint {
                changedDuringWork = true
                result.sources[path] = old
            }
        }
        for path in post.sources.keys where previous.sources[path] == nil {
            if pre.sources[path]?.fingerprint != post.sources[path]?.fingerprint {
                changedDuringWork = true
                result.sources.removeValue(forKey: path)
            }
        }
        for (path, old) in previous.sourceResources {
            if pre.sourceResources[path]?.fingerprint != post.sourceResources[path]?.fingerprint {
                changedDuringWork = true
                result.sourceResources[path] = old
            }
        }
        return PreservedBaseline(snapshot: result, hasSourceChangesDuringWork: changedDuringWork)
    }

    private func compileTargets(in diff: HotReloadWorkspaceDiff) -> [BuildTarget] {
        var result: [BuildTarget] = []
        let sourcePaths = diff.changedSources.map(\.path)
            + diff.removedSources
            + diff.changedSourceResources.map(\.path)
            + diff.removedSourceResources
        for path in sourcePaths {
            guard let watch = plan.workspace.moduleWatch(forSourcePath: path) else { continue }
            if !result.contains(where: { $0.module.id == watch.target.module.id }) {
                result.append(watch.target)
            }
        }
        return result
    }

    // MARK: - 应用

    private func applyAndPublish(diff: HotReloadWorkspaceDiff, summary: inout HotReloadSummary) {
        if isStopped { return }

        let removed = diff.classChanges.filter { $0.kind == .removed }
        for change in removed {
            summary.failedClasses.append(HotReloadClassFailure(
                className: change.className,
                message: "类文件已从输出目录删除；JVM 无法卸载已加载的类。",
                kind: .classRemoved
            ))
            summary.notes.append("删除的类 \(change.className) 不会被 JVM 卸载，需要重启才能消失。")
        }
        let applicable = diff.classChanges.filter { $0.kind != .removed }

        if plan.delegatesApply {
            summary.didApply = false
            if applicable.isEmpty && summary.resourceChanges.isEmpty {
                summary.notes.append("没有需要交给外部后端的类或资源变更。")
            } else {
                summary.notes.append("已编译并写入 classpath；实际热更新 / 快速重启由 \(plan.provider.displayName) 完成。")
            }
            let detail = applicable.isEmpty && summary.resourceChanges.isEmpty
                ? "编译完成；没有需要交给外部后端的类或资源变更。"
                : "已把 \(applicable.count) 个类、\(summary.resourceChanges.count) 个资源变更写入 classpath；"
                    + "由 \(plan.provider.displayName) 负责实际热更新或快速重启。IdeaLightRun 不宣称类已被替换。"
            publish(.delegated, detail: detail, summary: summary)
            log("[HotReload] \(summary.consoleLine)；已交给 \(plan.provider.displayName)。")
            return
        }

        lock.lock()
        let ready = backendReady
        let client = agentClient
        lock.unlock()
        guard ready, let client else {
            summary.notes.append("Agent 不可用，未发送类替换请求。")
            publish(.agentUnavailable, detail: "Agent 不可用，无法应用本次变更。", summary: summary)
            return
        }

        if applicable.isEmpty {
            if !summary.resourceChanges.isEmpty {
                summary.notes.append("资源已写入输出目录；标准 HotSwap 不会让框架重新加载资源。")
                publish(
                    .partial,
                    detail: "资源变更已写入输出目录；运行中的框架是否需要重启才能刷新资源，IdeaLightRun 无法保证。",
                    summary: summary
                )
                log("[HotReload] \(summary.consoleLine)；资源刷新取决于框架。")
            } else if !removed.isEmpty {
                handleFallback(
                    reason: "被删除的类无法从运行中的 JVM 移除。",
                    summary: &summary
                )
            } else {
                publish(.succeeded, detail: "编译成功，输出的字节码没有变化。", summary: summary)
                log("[HotReload] 编译成功，字节码没有变化。")
            }
            return
        }

        publish(.applying, detail: "正在替换 \(applicable.count) 个类…")
        var resultsByName: [String: HotReloadAgentClassResult] = [:]
        let batches = stride(from: 0, to: applicable.count, by: 50).map {
            Array(applicable[$0..<min($0 + 50, applicable.count)])
        }
        var agentFailure: String?
        for batch in batches {
            if isStopped { return }
            do {
                let response = try client.reload(classes: batch.map { ($0.className, $0.filePath) })
                if response.status == .unauthorized {
                    throw IdeaLightRunError.hotReloadUnavailable(
                        detail: "内置 Agent 拒绝了控制凭据，热更新通道已失效。"
                    )
                }
                for result in response.classes {
                    resultsByName[result.className] = result
                }
                if response.classes.isEmpty, response.status != .ok {
                    throw IdeaLightRunError.hotReloadUnavailable(
                        detail: "内置 Agent 返回错误：\(response.message)"
                    )
                }
            } catch {
                agentFailure = (error as? IdeaLightRunError)?.localizedDescription
                    ?? error.localizedDescription
                break
            }
        }

        if let agentFailure {
            for change in applicable where resultsByName[change.className] == nil {
                summary.failedClasses.append(HotReloadClassFailure(
                    className: change.className,
                    message: agentFailure,
                    kind: .agentUnreachable
                ))
            }
            summary.notes.append("Agent 控制通道失败：\(agentFailure)")
            handleAgentUnavailable(reason: agentFailure, summary: &summary)
            return
        }

        for change in applicable {
            guard let result = resultsByName[change.className] else {
                summary.failedClasses.append(HotReloadClassFailure(
                    className: change.className,
                    message: "Agent 响应中没有这个类。",
                    kind: .unknown
                ))
                continue
            }
            switch result.code {
            case .applied:
                summary.appliedClasses.append(change.className)
            case .skipped:
                let kind = HotReloadFailureKind.classify(result.message)
                summary.skippedClasses.append(HotReloadClassFailure(
                    className: change.className,
                    message: result.message,
                    kind: kind
                ))
                if change.kind == .added || kind == .notLoaded {
                    summary.notes.append("新增类 \(change.className) 尚未加载：JVM 会在首次引用时加载它；不会自动注册为 Spring Bean。")
                }
            case .failed:
                let kind = HotReloadFailureKind.classify(result.message)
                summary.failedClasses.append(HotReloadClassFailure(
                    className: change.className,
                    message: result.message,
                    kind: kind
                ))
            }
        }

        let structuralFailures = summary.failedClasses.filter { $0.kind.requiresEnhancedAgentOrRestart }
        let hasNonStructuralFailures = summary.failedClasses.contains {
            !$0.kind.requiresEnhancedAgentOrRestart
        }
        let hasOnlySkipped = summary.failedClasses.isEmpty && !summary.skippedClasses.isEmpty
        let resourceCaveat = !summary.resourceChanges.isEmpty
        summary.didApply = !summary.appliedClasses.isEmpty

        logDetailedResults(summary)

        if !structuralFailures.isEmpty {
            let reason = structuralFailures
                .prefix(3)
                .map { "\($0.className)：\($0.kind.displayText)" }
                .joined(separator: "；")
            handleFallback(
                reason: "标准 HotSwap 无法处理结构变更（\(reason)）。",
                summary: &summary
            )
            return
        }

        if hasNonStructuralFailures {
            let detail = summary.failedClasses
                .prefix(3)
                .map { "\($0.className)：\($0.message)" }
                .joined(separator: "；")
            publish(
                summary.appliedClasses.isEmpty ? .failed : .partial,
                detail: summary.appliedClasses.isEmpty
                    ? "类替换失败：\(detail)"
                    : "部分类替换成功，\(summary.failedClasses.count) 个失败：\(detail)",
                summary: summary
            )
            log("[HotReload] \(summary.consoleLine)。")
            return
        }

        if summary.appliedClasses.isEmpty, hasOnlySkipped {
            publish(
                .partial,
                detail: "有 \(summary.skippedClasses.count) 个类未替换（通常为尚未加载的新类）；其余变更已处理。",
                summary: summary
            )
            log("[HotReload] \(summary.consoleLine)。")
            return
        }

        if resourceCaveat {
            summary.notes.append("资源已写入输出目录；框架缓存是否刷新不受 IdeaLightRun 控制。")
            publish(
                .partial,
                detail: "已替换 \(summary.appliedClasses.count) 个类；资源变更已写入输出目录，框架可能需要重启才能刷新。",
                summary: summary
            )
        } else if summary.skippedClasses.isEmpty {
            publish(
                .succeeded,
                detail: "已替换 \(summary.appliedClasses.count) 个类，JVM 未报告结构变更。",
                summary: summary
            )
        } else {
            summary.notes.append("有 \(summary.skippedClasses.count) 个新增类尚未加载，未替换。")
            publish(
                .partial,
                detail: "已替换 \(summary.appliedClasses.count) 个类；\(summary.skippedClasses.count) 个新类尚未加载。",
                summary: summary
            )
        }
        log("[HotReload] \(summary.consoleLine)。")
    }

    // MARK: - 回退

    private func handleFallback(reason: String, summary: inout HotReloadSummary) {
        lock.lock()
        pendingRestartReason = reason
        lock.unlock()
        let policy = plan.configuration.restartPolicy
        switch policy {
        case .notify:
            summary.notes.append("回退策略为仅提示，未重启应用。")
            publish(
                .requiresRestart,
                detail: "需要重启：\(reason) 当前策略仅提示，请手动重启应用。",
                summary: summary
            )
            log("[HotReload] 需要重启：\(reason) 当前策略仅提示。")
        case .ask:
            publish(
                .requiresRestart,
                detail: "需要重启：\(reason) 是否现在重启应用？",
                summary: summary,
                awaitingRestart: true
            )
            log("[HotReload] 需要重启：\(reason) 已请求用户确认。")
        case .automatic:
            lock.lock()
            let alreadyRequested = restartRequested
            restartRequested = true
            lock.unlock()
            guard !alreadyRequested else { return }
            if onRestartRequested?(reason) == true {
                summary.didRestart = true
                summary.notes.append("已按自动重启策略请求重启。")
                publish(
                    .restarted,
                    detail: "需要重启：\(reason) 已按自动重启策略请求重启，等待旧进程退出后重新启动。",
                    summary: summary
                )
                log("[HotReload] 需要重启：\(reason) 已按自动重启策略请求重启。")
            } else {
                summary.notes.append("回退策略为自动重启，但当前宿主没有提供重启入口。")
                publish(
                    .requiresRestart,
                    detail: "需要重启：\(reason) 自动重启入口不可用，请手动重启。",
                    summary: summary,
                    awaitingRestart: true
                )
                log("[HotReload] 需要重启：\(reason) 自动重启入口不可用。")
            }
        }
    }

    private func handleAgentUnavailable(reason: String, summary: inout HotReloadSummary) {
        lock.lock()
        backendReady = false
        agentClient = nil
        pendingRestartReason = reason
        lock.unlock()
        let policy = plan.configuration.restartPolicy
        var shouldRestart = false
        if policy == .automatic {
            lock.lock()
            let alreadyRequested = restartRequested
            restartRequested = true
            lock.unlock()
            if !alreadyRequested, let onRestartRequested, onRestartRequested(reason) {
                shouldRestart = true
                summary.didRestart = true
                summary.notes.append("已按自动重启策略请求重启。")
            }
        }

        let detail: String
        let awaiting: Bool
        if shouldRestart {
            detail = "Agent 控制通道不可用：\(reason) 已按自动重启策略请求重启，等待旧进程退出后重新启动。"
            awaiting = false
        } else if policy == .ask {
            detail = "Agent 控制通道不可用：\(reason) 是否重启应用以重建通道？"
            awaiting = true
        } else {
            detail = "Agent 控制通道不可用：\(reason)"
            awaiting = false
        }
        publish(.agentUnavailable, detail: detail, summary: summary, awaitingRestart: awaiting)
        log("[HotReload] Agent 控制通道不可用：\(reason)")
    }

    // MARK: - 状态与日志

    private func publish(
        _ state: HotReloadState,
        detail: String,
        summary: HotReloadSummary? = nil,
        awaitingRestart: Bool = false
    ) {
        lock.lock()
        if stopped && state != .stopped {
            lock.unlock()
            return
        }
        self.state = state
        self.detail = detail
        if let summary { self.summary = summary }
        self.awaitingRestart = awaitingRestart
        let snapshot = makeSnapshotLocked()
        lock.unlock()
        onSnapshot(snapshot)
    }

    private func makeSnapshotLocked() -> HotReloadSnapshot {
        HotReloadSnapshot(
            state: state,
            detail: detail,
            configuration: plan.configuration,
            provider: plan.provider,
            capability: plan.capability,
            summary: summary,
            awaitingRestartConfirmation: awaitingRestart,
            canManualTrigger: !stopped && !isProcessing && (backendReady || plan.delegatesApply),
            isWatching: watcher != nil,
            lastUpdated: Date()
        )
    }

    private func makeSummary(
        diff: HotReloadWorkspaceDiff,
        compiledModules: [String],
        didCompile: Bool,
        startedAt: Date
    ) -> HotReloadSummary {
        HotReloadSummary(
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            sourceChanges: diff.sourceChanges(projectRoot: plan.workspace.projectRoot),
            resourceChanges: diff.resourceChanges(projectRoot: plan.workspace.projectRoot),
            compiledModules: compiledModules,
            classChanges: diff.classChanges,
            didCompile: didCompile
        )
    }

    private func logDetailedResults(_ summary: HotReloadSummary) {
        if !summary.appliedClasses.isEmpty {
            let preview = summary.appliedClasses.prefix(12).joined(separator: "、")
            let suffix = summary.appliedClasses.count > 12 ? " 等 \(summary.appliedClasses.count) 个" : ""
            log("[HotReload] 已替换类：\(preview)\(suffix)。")
        }
        for failure in summary.failedClasses.prefix(20) {
            log("[HotReload] 类 \(failure.className) 未替换（\(failure.kind.displayText)）：\(trimmed(failure.message))")
        }
        if summary.failedClasses.count > 20 {
            log("[HotReload] 另有 \(summary.failedClasses.count - 20) 个类替换失败，详见状态面板。")
        }
        for skipped in summary.skippedClasses.prefix(10) {
            log("[HotReload] 类 \(skipped.className) 跳过：\(trimmed(skipped.message))")
        }
    }

    private func logOnceTruncation() {
        lock.lock()
        let alreadyLogged = truncatedLogged
        truncatedLogged = true
        lock.unlock()
        if !alreadyLogged {
            log("[HotReload] 警告：监听文件数超过上限，部分变更可能不会被发现。")
        }
    }

    private func trimmed(_ message: String) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 400 ? String(singleLine.prefix(400)) + "…" : singleLine
    }
}
