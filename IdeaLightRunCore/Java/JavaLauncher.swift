import Foundation

/// §58: 启动流水线：扫描 → Module/JDK/构建工具 → Before Launch（§3.2）
/// → classpath（§3.1：只做依赖解析，不夹带 compile）→ 配置解析（§4/§5）→ LaunchPlan。
///
/// §3.3: 编译只在配置里真的有 Make / Build Project 时发生。IDEA 勾了
/// "Do not build before run" 的配置，这里就一次编译都不会跑。
/// GUI 与 CLI 共用，禁止另起一套（§4）。
public struct JavaLauncher: Sendable {
    public init() {}

    public func prepare(
        config: RunConfiguration,
        projectRoot: URL,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle? = nil
    ) async throws -> JavaLaunchPlan {
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
    ) async throws -> JavaLaunchPlan {
        let scanner = IntelliJProjectScanner()
        let result = try scanner.scan(projectRoot: projectRoot)

        // ① Module 解析（§13）
        let moduleResolution = ModuleResolver.resolveModule(
            named: config.moduleName,
            mainClass: config.mainClass,
            projectRoot: projectRoot,
            knownModules: result.modules
        )
        guard let module = moduleResolution.module else {
            let detail = moduleResolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.moduleNotFound(detail: detail.isEmpty ? "无法定位 module。" : detail)
        }

        // ②③ JDK + 构建工具（§23/§15，与项目级构建共用 ProjectToolchain）
        let toolchain = try ProjectToolchain.resolve(
            projectRoot: projectRoot,
            result: result,
            configJDKName: config.jreReference,
            context: "启动",
            log: log
        )
        let jdk = toolchain.jdk

        let reactor = MavenPomReader.collectReactor(rootPom: toolchain.rootPomURL)
        let reactorModule = reactor.first { $0.directory.standardizedFileURL == module.directory.standardizedFileURL }
            ?? reactor.first { $0.artifactId == module.name }
        // reactor 中存在非根模块即视为多模块（§16）
        let isMultiModule = reactor.contains { $0.directory.standardizedFileURL != projectRoot.standardizedFileURL }
        let reactorModuleName: String? = {
            guard isMultiModule else { return nil }
            guard let info = reactorModule else { return nil }
            // 根模块本身不需要 -pl
            if info.directory.standardizedFileURL == projectRoot.standardizedFileURL { return nil }
            return info.artifactId
        }()

        let service = toolchain.service
        // §6.1: includeProvided 是 classpath 的一部分，不是全局属性——两个配置共用缓存会互相污染。
        let variant = ClasspathVariant.maven(
            module: module.name,
            includeProvided: config.includeProvidedDependencies
        )
        let gateKey = projectRoot.standardizedFileURL.path
        let owner = gateOwner ?? BuildGate.Owner()

        // §3.1/§3.3: 先判断 classpath 是否需要重新解析，再决定 Build 怎么跑。
        // 需要解析时把 compile 合进那一次 Maven 调用（兄弟模块的未 install
        // SNAPSHOT 只有在同一次会话里编译过才能被解析到），这样冷启动仍然
        // 只 compile 一次、只解析一次；缓存命中时 compile 单独跑。
        let preFingerprint = ClasspathCache.mavenFingerprint(
            projectRoot: projectRoot,
            reactorPoms: reactor.map(\.pomURL),
            jdkMajor: jdk.majorVersion
        )
        let needsClasspathResolve = ClasspathCache.load(projectRoot: projectRoot, variant: variant)?
            .fingerprint != preFingerprint
        let deferredBuild = DeferredBuild()

        return try await BuildGate.shared.run(projectKey: gateKey, owner: owner) {
            // ④ §3.2: Before Launch（Build / Build Project / Maven goal / 被引用的运行配置）
            try await BeforeLaunchExecutor().run(
                for: config,
                configurations: result.configurations,
                actions: BeforeLaunchExecutor.Actions(
                    build: {
                        progress(.building)
                        if needsClasspathResolve {
                            deferredBuild.pending = true
                            log(LogLine(stream: .system, text: "[IdeaLightRun] 编译将与依赖解析合并为一次 Maven 调用（避免重复 compile）"))
                        } else {
                            log(LogLine(stream: .system, text: "[IdeaLightRun] 编译 \(reactorModuleName ?? module.name) …"))
                            try service.compile(
                                reactorModuleName: reactorModuleName,
                                hasModules: isMultiModule,
                                handle: processHandle,
                                log: log
                            )
                        }
                    },
                    buildProject: {
                        progress(.building)
                        try service.buildProject(kind: .build, handle: processHandle, log: log)
                    },
                    runMavenGoals: { goals in
                        progress(.building)
                        try service.runGoals(goals, handle: processHandle, log: log)
                    },
                    runReferenced: { referenced, chain in
                        let referencedPlan = try await prepare(
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

            // ⑤ classpath：缓存命中 or 只解析依赖（§3.1 起 cold resolve 不再夹带第二次 compile）
            progress(.resolvingClasspath)
            // Before Launch 里的 Maven goal 可能改过 pom，指纹按最新内容算
            let fingerprint = ClasspathCache.mavenFingerprint(
                projectRoot: projectRoot,
                reactorPoms: reactor.map(\.pomURL),
                jdkMajor: jdk.majorVersion
            )
            let classpath: [String]
            if let cached = ClasspathCache.load(projectRoot: projectRoot, variant: variant),
               cached.fingerprint == fingerprint {
                if deferredBuild.pending {
                    // 启动前判断要解析、解析时却发现命中（pom 被 Before Launch 改回原样）：
                    // 推迟掉的 Build 不能就此消失。
                    log(LogLine(stream: .system, text: "[IdeaLightRun] 编译 \(reactorModuleName ?? module.name) …"))
                    try service.compile(
                        reactorModuleName: reactorModuleName,
                        hasModules: isMultiModule,
                        handle: processHandle,
                        log: log
                    )
                }
                classpath = cached.entries
                log(LogLine(stream: .system, text: "[IdeaLightRun] classpath 命中缓存（\(classpath.count) 项）"))
            } else {
                log(LogLine(stream: .system, text: "[IdeaLightRun] 解析 runtime classpath（pom/JDK 变化或首次运行）…"))
                let rawEntries = try service.resolveRuntimeClasspath(
                    reactorModuleName: reactorModuleName,
                    hasModules: isMultiModule,
                    includeProvided: config.includeProvidedDependencies,
                    withCompile: deferredBuild.pending,
                    runtimeOutputFile: ClasspathCache.mavenOutputFileURL(
                        projectRoot: projectRoot, variant: variant, scope: .runtime
                    ),
                    providedOutputFile: ClasspathCache.mavenOutputFileURL(
                        projectRoot: projectRoot, variant: variant, scope: .compile
                    ),
                    handle: processHandle,
                    log: log
                )
                classpath = MavenClasspathResolver.normalize(
                    entries: rawEntries,
                    reactor: reactor,
                    targetModuleDirectory: module.directory
                )
                ClasspathCache.store(
                    CachedClasspath(
                        module: module.name,
                        entries: classpath,
                        fingerprint: fingerprint,
                        resolvedAt: Date()
                    ),
                    projectRoot: projectRoot,
                    variant: variant
                )
                log(LogLine(stream: .system, text: "[IdeaLightRun] classpath 解析完成（\(classpath.count) 项），已缓存"))
            }

            // ⑥ 配置解析：宏、环境文件、Working Directory（§4/§5）
            let resolved = try RunConfigurationResolver().resolve(
                config: config,
                projectRoot: projectRoot,
                module: module,
                jdk: jdk
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

            // ⑦ LaunchPlan（§26）
            progress(.starting)
            return try LaunchPlanBuilder.build(resolved: resolved, classpath: classpath, jdk: jdk)
        }
    }

    // MARK: - 被引用配置的完整执行（§3.7）

    /// Before Launch 引用的运行配置要像 IDEA 那样先跑完再回来：
    /// 启动进程、把输出并进当前会话的日志、等它退出；退出码非 0 时中止本次启动。
    private static func runUntilExit(
        plan: JavaLaunchPlan,
        configName: String,
        processHandle: ProcessHandle?,
        log: @escaping LogCallback
    ) async throws {
        let session = try ProcessSession(
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

/// Before Launch 决定要 Build、但 compile 被推迟到依赖解析那一次调用里执行。
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
