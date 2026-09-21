import Foundation

/// §8: 唯一的启动入口。GUI 与 CLI 都只调用这里（§24 约束 13），
/// 「这个配置能不能跑、用什么构建系统、Before Launch 怎么执行」全部在 Core 这条链上决定。
///
/// 流水线：类型门禁 → Module（§13）→ BuildSystemResolver（§9）
/// → Before Launch（§3.2）→ runtime classpath（§3.1）
/// → RunConfigurationResolver（§4/§5）→ JavaRunPlanner → `ExecutableLaunchPlan`（§7）。
///
/// §3.3: 编译只在配置里真的有 Make / Build Project 时发生。IDEA 勾了
/// "Do not build before run" 的配置，这里一次编译都不会跑。
public struct ExecutionCoordinator: Sendable {
    public init() {}

    public func prepare(
        config: RunConfiguration,
        projectRoot: URL,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle? = nil
    ) async throws -> ExecutableLaunchPlan {
        try await prepare(
            config: config,
            projectRoot: projectRoot,
            log: log,
            progress: progress,
            processHandle: processHandle,
            gateOwner: nil,
            visiting: []
        )
    }

    /// - Parameters:
    ///   - gateOwner: Before Launch 引用同一项目的其他配置时复用的构建闸门持有者；
    ///     不复用会自锁（§3.7）。
    ///   - visiting: 已走过的配置名，用于循环检测。
    private func prepare(
        config: RunConfiguration,
        projectRoot: URL,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        gateOwner: BuildGate.Owner?,
        visiting: [String]
    ) async throws -> ExecutableLaunchPlan {
        try Self.ensureRunnable(config)
        let scan = try IntelliJProjectScanner().scan(projectRoot: projectRoot)

        // ① Module 解析（§13）
        let moduleResolution = ModuleResolver.resolveModule(
            named: config.moduleName,
            mainClass: config.mainClass,
            projectRoot: projectRoot,
            knownModules: scan.modules
        )
        guard let module = moduleResolution.module else {
            let detail = moduleResolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.moduleNotFound(detail: detail.isEmpty ? "无法定位 module。" : detail)
        }

        // ②③ JDK + 构建系统（§23/§15/§9）
        let build = try BuildSystemResolver.resolve(
            projectRoot: projectRoot,
            result: scan,
            config: config,
            module: module,
            log: log
        )
        let adapter = build.adapter
        let target = build.target
        let owner = gateOwner ?? BuildGate.Owner()
        // §3.1/§3.3: 先知道 classpath 要不要重新解析，再决定 Build 怎么跑——
        // 需要解析时把编译合进那一次调用，冷启动就只 compile 一次、只解析一次。
        let deferredBuild = DeferredBuild()

        return try await BuildGate.shared.run(projectKey: projectRoot.standardizedFileURL.path, owner: owner) {
            // ④ Before Launch（§3.2）
            try await BeforeLaunchExecutor().run(
                for: config,
                configurations: scan.configurations,
                actions: BeforeLaunchExecutor.Actions(
                    build: {
                        progress(.building)
                        if adapter.hasFreshClasspathCache(for: target) {
                            try adapter.buildModule(target, handle: processHandle, log: log)
                        } else {
                            deferredBuild.pending = true
                            log(LogLine(stream: .system, text: "[IdeaLightRun] 编译将与依赖解析合并为一次调用（避免重复编译）"))
                        }
                    },
                    buildProject: {
                        progress(.building)
                        try adapter.buildProject(kind: .build, handle: processHandle, log: log)
                    },
                    runMavenGoals: { goals in
                        progress(.building)
                        try adapter.runTasks(goals, handle: processHandle, log: log)
                    },
                    runReferenced: { referenced, chain in
                        let referencedPlan = try await self.prepare(
                            config: referenced,
                            projectRoot: projectRoot,
                            log: log,
                            progress: progress,
                            processHandle: processHandle,
                            gateOwner: owner,
                            visiting: chain
                        )
                        try await Self.runUntilExit(
                            plan: referencedPlan,
                            configName: referenced.name,
                            processHandle: processHandle,
                            log: log
                        )
                    }
                ),
                visiting: visiting,
                handle: processHandle,
                log: log
            )

            // ⑤ classpath：缓存命中或只解析依赖（§3.1：解析不夹带编译）
            progress(.resolvingClasspath)
            let classpath = try adapter.runtimeClasspath(
                target,
                withBuild: deferredBuild.pending,
                handle: processHandle,
                log: log
            )

            // ⑥ 配置解析：宏、环境文件、Working Directory（§4/§5）
            let resolved = try RunConfigurationResolver().resolve(
                config: config,
                projectRoot: projectRoot,
                module: module,
                jdk: build.jdk
            )
            // §5: 告警必须看得见——以前 resolve(x).value 把 warnings 直接丢掉。
            for warning in resolved.warnings {
                log(LogLine(stream: .system, text: "[IdeaLightRun] 警告（\(warning.title)）：\(warning.detail)"))
            }
            if !resolved.loadedEnvironmentFiles.isEmpty {
                // §17: 只报路径与键数，不报内容。
                let keys = resolved.source.environmentVariables.count
                log(LogLine(stream: .system, text: "[IdeaLightRun] 环境文件已加载 \(resolved.loadedEnvironmentFiles.count) 个，配置变量 \(keys) 个"))
            }

            // ⑦ 启动计划（§26/§7）
            progress(.starting)
            return try JavaRunPlanner.plan(resolved: resolved, classpath: classpath, jdk: build.jdk)
        }
    }

    // MARK: - 类型门禁（§23）

    /// 运行类型判断留在 Core：GUI / CLI 不许自己 `if Maven`、`if SpringBoot`。
    /// 支持的类型集合只有 `supportLevel` 一处定义，界面徽标与门禁不会漂移。
    static func ensureRunnable(_ config: RunConfiguration) throws {
        guard config.type.supportLevel == .supported else {
            throw IdeaLightRunError.unsupportedConfiguration(
                detail: "“\(config.name)”（\(config.type.displayName)）当前不能直接启动；"
                    + "现在能替代 IDEA Run 按钮的是 Application 与 Spring Boot 配置。"
            )
        }
    }

    // MARK: - 被引用配置的完整执行（§3.7）

    /// Before Launch 引用的运行配置要像 IDEA 那样先跑完再回来：
    /// 启动进程、把输出并进当前会话的日志、等它退出；退出码非 0 时中止本次启动。
    private static func runUntilExit(
        plan: ExecutableLaunchPlan,
        configName: String,
        processHandle: ProcessHandle?,
        log: @escaping LogCallback
    ) async throws {
        let session = try ManagedProcessSession(
            configKey: "before-launch::\(configName)",
            configName: configName,
            plan: plan
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let sink = ResumeSink(continuation)
            session.onState = { state in
                if let outcome = Self.outcome(for: state, configName: configName) {
                    sink.resume(with: outcome)
                }
            }
            session.onLogLines = { lines in lines.forEach(log) }
            session.start()
            // Stop 落在嵌套进程上：外层只有构建句柄，这里代为转达，
            // SIGTERM 后仍不退出就强杀，避免被引用的进程把本次启动永久挂住。
            Task.detached(priority: .userInitiated) {
                while !session.state.isTerminal {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if processHandle?.isCancelled == true {
                        session.stop()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if !session.state.isTerminal { session.forceKill() }
                        return
                    }
                }
            }
        }
    }

    static func outcome(for state: ProcessState, configName: String) -> Result<Void, Error>? {
        switch state {
        case .exited(let code):
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
}

/// Before Launch 决定要 Build、但编译被推迟到依赖解析那一次调用里执行。
/// 闭包跨线程读写，用锁保证只看到 true/false 两种确定状态。
private final class DeferredBuild: @unchecked Sendable {
    private let lock = NSLock()
    private var _pending = false

    var pending: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _pending
        }
        set {
            lock.lock()
            _pending = newValue
            lock.unlock()
        }
    }
}

/// continuation 只能 resume 一次：终态路径（退出码 / 失败 / 取消）交错时
/// 重复 resume 会直接崩溃，这里显式去重。
private final class ResumeSink: @unchecked Sendable {
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
