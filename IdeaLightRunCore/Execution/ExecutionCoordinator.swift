import Foundation

/// §8: 唯一的启动入口。GUI 与 CLI 都只调用这里（§24 约束 13），
/// 「这个配置能不能跑、用什么构建系统、Before Launch 怎么执行」全部在 Core 这条链上决定。
///
/// 流水线：类型门禁 → Module（§13）→ BuildSystemResolver（§9）
/// → Before Launch（§3.2）→ runtime classpath（§3.1）
/// → RunConfigurationResolver（§4/§5）→ Planner → `PreparedExecution`（§7）。
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
    ) async throws -> PreparedExecution {
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
    ) async throws -> PreparedExecution {
        // §P0-10: 清掉上次异常遗留的启动产物（@argfile / manifest jar）
        LaunchArtifactStore.cleanupOrphans()
        // 先做类型/字段门禁，项目根不存在时也要先给出「这个配置不能跑」。
        try Self.ensureRunnable(config)
        let scan = try IntelliJProjectScanner().scan(projectRoot: projectRoot)
        // 再按项目实际构建系统与 Before Launch 引用做完整能力检查。
        try Self.ensureRunnable(config, scan: scan)

        if config.type == .jar {
            return try await prepareJar(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                log: log,
                progress: progress,
                processHandle: processHandle,
                gateOwner: gateOwner,
                visiting: visiting
            )
        }

        return try await prepareJavaApplication(
            config: config,
            projectRoot: projectRoot,
            scan: scan,
            log: log,
            progress: progress,
            processHandle: processHandle,
            gateOwner: gateOwner,
            visiting: visiting
        )
    }

    // MARK: - Application / Spring Boot

    private func prepareJavaApplication(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        gateOwner: BuildGate.Owner?,
        visiting: [String]
    ) async throws -> PreparedExecution {
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
                    runMavenGoals: { goals, pomFile in
                        progress(.building)
                        try adapter.runTasks(
                            goals,
                            pomFile: pomFile,
                            moduleDirectory: module.directory,
                            handle: processHandle,
                            log: log
                        )
                    },
                    runReferenced: { referenced, chain in
                        let referencedExecution = try await self.prepare(
                            config: referenced,
                            projectRoot: projectRoot,
                            log: log,
                            progress: progress,
                            processHandle: processHandle,
                            gateOwner: owner,
                            visiting: chain
                        )
                        try await ExecutionRuntime.runUntilExit(
                            execution: referencedExecution,
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
            Self.logResolvedConfiguration(resolved, log: log)

            // ⑦ 启动计划（§26/§7）
            progress(.starting)
            return .process(try JavaRunPlanner.plan(resolved: resolved, classpath: classpath, jdk: build.jdk))
        }
    }

    // MARK: - JAR Application

    /// §5: JAR 不要求 Main Class、项目 classpath 或构建系统本身。
    /// Module 仅用于 `$MODULE_DIR$` 与 Before Launch 的 Build；
    /// 只有出现构建类任务时才解析 Maven 工具链。
    private func prepareJar(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        gateOwner: BuildGate.Owner?,
        visiting: [String]
    ) async throws -> PreparedExecution {
        let module = ModuleResolver.resolveModule(
            named: config.moduleName,
            mainClass: nil,
            projectRoot: projectRoot,
            knownModules: scan.modules
        ).module

        let tasks = config.beforeLaunchTasks.filter(\.isEnabled)
        let needsMavenToolchain = tasks.contains { task in
            switch task.kind {
            case .build, .buildProject, .mavenGoal:
                return true
            case .runConfiguration, .gradleTask, .unknown:
                return false
            }
        }

        let toolchain: ProjectToolchain?
        if needsMavenToolchain {
            toolchain = try ProjectToolchain.resolve(
                projectRoot: projectRoot,
                result: scan,
                config: config,
                configJDKName: config.jreReference,
                context: "启动",
                log: log
            )
        } else {
            toolchain = nil
        }
        let jdk = try toolchain?.jdk ?? Self.resolveJDK(config: config, scan: scan, log: log)

        let owner = gateOwner ?? BuildGate.Owner()
        return try await BuildGate.shared.run(projectKey: projectRoot.standardizedFileURL.path, owner: owner) {
            try await BeforeLaunchExecutor().run(
                for: config,
                configurations: scan.configurations,
                actions: BeforeLaunchExecutor.Actions(
                    build: {
                        guard let toolchain, let module else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 是 JAR Application，Before Launch 的 Build "
                                    + "需要可解析的 Module 与 Maven 项目。"
                            )
                        }
                        progress(.building)
                        let target = BuildTarget(
                            module: module,
                            variant: .maven(
                                module: module.name,
                                includeProvided: config.includeProvidedDependencies
                            )
                        )
                        try toolchain.service.buildModule(target, handle: processHandle, log: log)
                    },
                    buildProject: {
                        guard let toolchain else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 的 Before Launch 需要 Build Project，但当前项目无法使用 Maven。"
                            )
                        }
                        progress(.building)
                        try toolchain.service.buildProject(kind: .build, handle: processHandle, log: log)
                    },
                    runMavenGoals: { goals, pomFile in
                        guard let toolchain else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 的 Before Launch 需要 Maven，但当前项目无法使用 Maven。"
                            )
                        }
                        progress(.building)
                        try toolchain.service.runTasks(
                            goals,
                            pomFile: pomFile,
                            moduleDirectory: module?.directory ?? projectRoot,
                            handle: processHandle,
                            log: log
                        )
                    },
                    runReferenced: { referenced, chain in
                        let referencedExecution = try await self.prepare(
                            config: referenced,
                            projectRoot: projectRoot,
                            log: log,
                            progress: progress,
                            processHandle: processHandle,
                            gateOwner: owner,
                            visiting: chain
                        )
                        try await ExecutionRuntime.runUntilExit(
                            execution: referencedExecution,
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

            // Before Launch 可能刚刚产出 JAR，存在性必须在这之后校验。
            progress(.starting)
            let resolved = try RunConfigurationResolver().resolve(
                config: config,
                projectRoot: projectRoot,
                module: module,
                jdk: jdk
            )
            Self.logResolvedConfiguration(resolved, log: log)
            return .process(try JarRunPlanner.plan(resolved: resolved, jdk: jdk))
        }
    }

    // MARK: - 能力门禁（§23/§P0-5）

    /// 运行类型判断留在 Core：GUI / CLI 不许自己 `if Maven`、`if SpringBoot`。
    /// 可运行性由 `ConfigurationCapabilityResolver` 统一计算，界面徽标与门禁同源。
    static func ensureRunnable(_ config: RunConfiguration) throws {
        try ensureRunnable(ConfigurationCapabilityResolver.resolve(config), for: config)
    }

    /// 项目感知门禁：构建系统缺失或落到尚未接管的 Gradle 时，
    /// 沿用 `buildToolNotFound` 的既有语义，让调用方拿到明确的工具链原因。
    /// JAR Application 不需要构建系统本身，缺失原因（JAR Path / Before Launch）按配置错误报告。
    static func ensureRunnable(_ config: RunConfiguration, scan: ScanResult) throws {
        let capability = ConfigurationCapabilityResolver.resolve(config, scan: scan)
        guard !capability.isLaunchable else { return }
        if config.type != .jar, capability.buildSystem != .maven {
            throw IdeaLightRunError.buildToolNotFound(
                detail: capability.primaryReason ?? "无法确定项目的构建系统。"
            )
        }
        try ensureRunnable(capability, for: config)
    }

    private static func ensureRunnable(
        _ capability: ConfigurationCapability,
        for config: RunConfiguration
    ) throws {
        guard !capability.isLaunchable else { return }
        let reason = capability.primaryReason ?? "当前版本尚未接管该类型。"
        throw IdeaLightRunError.unsupportedConfiguration(
            detail: "“\(config.name)”（\(config.type.displayName)）当前不能直接启动：\(reason)"
                + " 现在能替代 IDEA Run 按钮的是 Application、Spring Boot 与 JAR Application 配置。"
        )
    }

    // MARK: - 内部

    private static func resolveJDK(
        config: RunConfiguration,
        scan: ScanResult,
        log: @escaping LogCallback
    ) throws -> JDKInstallation {
        let resolution = JDKResolver().resolve(
            configJDKName: config.jreReference,
            projectJDKName: scan.projectJDKName
        )
        guard let jdk = resolution.installation else {
            let detail = resolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.jdkNotFound(detail: detail.isEmpty ? "未找到可用 JDK。" : detail)
        }
        log(LogLine(
            stream: .system,
            text: "[IdeaLightRun] JDK: \(jdk.displayName ?? jdk.home.lastPathComponent) "
                + "(major \(jdk.majorVersion.map(String.init) ?? "?"))"
        ))
        return jdk
    }

    private static func logResolvedConfiguration(
        _ resolved: ResolvedRunConfiguration,
        log: @escaping LogCallback
    ) {
        // §5: 告警必须看得见——以前 resolve(x).value 把 warnings 直接丢掉。
        for warning in resolved.warnings {
            log(LogLine(stream: .system, text: "[IdeaLightRun] 警告（\(warning.title)）：\(warning.detail)"))
        }
        if !resolved.loadedEnvironmentFiles.isEmpty {
            // §17: 只报路径与键数，不报内容。
            let keys = resolved.source.environmentVariables.count
            log(LogLine(stream: .system, text: "[IdeaLightRun] 环境文件已加载 \(resolved.loadedEnvironmentFiles.count) 个，配置变量 \(keys) 个"))
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
