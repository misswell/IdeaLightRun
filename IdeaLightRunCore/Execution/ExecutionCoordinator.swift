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
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider = { _ in nil },
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle? = nil
    ) async throws -> PreparedExecution {
        // §P0-10: 清掉上次异常遗留的启动产物（@argfile / manifest jar）
        LaunchArtifactStore.cleanupOrphans()
        // 先做类型/字段门禁，项目根不存在时也要先给出「这个配置不能跑」。
        try Self.ensureRunnable(config)
        let scan = try IntelliJProjectScanner().scan(projectRoot: projectRoot)
        return try await prepareResolved(
            config: config,
            projectRoot: projectRoot,
            scan: scan,
            hotReloadConfigurationFor: hotReloadConfigurationFor,
            log: log,
            progress: progress,
            processHandle: processHandle,
            gateOwner: nil,
            visiting: []
        )
    }

    /// - Parameters:
    ///   - scan: 一次启动共用同一份扫描结果；Compound 成员不再各自扫盘。
    ///   - gateOwner: Before Launch 引用同一项目的其他配置时复用的构建闸门持有者；
    ///     不复用会自锁（§3.7）。
    ///   - visiting: 已走过的配置名（Compound 嵌套 + Before Launch 引用），用于循环检测。
    private func prepareResolved(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        gateOwner: BuildGate.Owner?,
        visiting: [String]
    ) async throws -> PreparedExecution {
        // 再按项目实际构建系统与 Before Launch 引用做完整能力检查。
        try Self.ensureRunnable(config, scan: scan)

        switch config.type {
        case .jar:
            return try await prepareJar(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                log: log,
                progress: progress,
                processHandle: processHandle,
                gateOwner: gateOwner,
                visiting: visiting
            )
        case .compound:
            return try await prepareCompound(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                log: log,
                progress: progress,
                processHandle: processHandle,
                gateOwner: gateOwner,
                visiting: visiting
            )
        case .application, .springBoot:
            return try await prepareJavaApplication(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                log: log,
                progress: progress,
                processHandle: processHandle,
                gateOwner: gateOwner,
                visiting: visiting
            )
        case .maven:
            return try await prepareMaven(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                log: log,
                progress: progress,
                processHandle: processHandle,
                gateOwner: gateOwner,
                visiting: visiting
            )
        case .junit:
            return try await prepareJUnit(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                log: log,
                progress: progress,
                processHandle: processHandle,
                gateOwner: gateOwner,
                visiting: visiting
            )
        case .gradle, .unknown:
            // ensureRunnable 已经拦下，这里只是保持 switch 穷尽。
            throw IdeaLightRunError.unsupportedConfiguration(
                detail: "“\(config.name)”（\(config.type.displayName)）当前不能直接启动。"
            )
        }
    }

    // MARK: - Application / Spring Boot

    private func prepareJavaApplication(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider,
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
                    runGradleTasks: { tasks in
                        progress(.building)
                        try adapter.runTasks(
                            tasks,
                            pomFile: nil,
                            moduleDirectory: module.directory,
                            handle: processHandle,
                            log: log
                        )
                    },
                    runReferenced: { referenced, chain in
                        let referencedExecution = try await self.prepareResolved(
                            config: referenced,
                            projectRoot: projectRoot,
                            scan: scan,
                            hotReloadConfigurationFor: hotReloadConfigurationFor,
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
            // §HotReload: 只在显式启用的开发配置上注入 Agent；默认返回 nil。
            let hotReloadPlan = hotReloadConfigurationFor(config).flatMap { configuration in
                HotReloadPlanner.makePlan(
                    configuration: configuration,
                    config: config,
                    projectRoot: projectRoot,
                    scan: scan,
                    module: module,
                    classpath: classpath,
                    adapter: adapter,
                    includeProvided: config.includeProvidedDependencies,
                    log: { text in log(LogLine(stream: .system, text: text)) }
                )
            }
            return .process(try JavaRunPlanner.plan(
                resolved: resolved,
                classpath: classpath,
                jdk: build.jdk,
                hotReload: hotReloadPlan
            ))
        }
    }

    // MARK: - Compound

    /// §Compound: 成员按 IDEA 的顺序逐个准备（每个成员跑自己的 Before Launch），
    /// 全部成功后才交给运行时统一启动。嵌套 Compound 在这里展开成叶子成员：
    /// 对用户来说等价于按顺序启动所有叶子配置，运行时也因此只有真实进程。
    private func prepareCompound(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        gateOwner: BuildGate.Owner?,
        visiting: [String]
    ) async throws -> PreparedExecution {
        guard config.beforeLaunchTasks.filter(\.isEnabled).isEmpty else {
            throw IdeaLightRunError.unsupportedBeforeLaunch(
                detail: "配置 “\(config.name)” 是 Compound；Compound 自身的 Before Launch 任务暂不支持执行。"
                    + "请把构建等任务放到成员配置中，IdeaLightRun 不会跳过它们直接启动。"
            )
        }
        guard !config.compoundMembers.isEmpty else {
            throw IdeaLightRunError.invalidConfiguration(detail: "配置 “\(config.name)” 没有引用任何子配置。")
        }

        let chain = visiting + [config.name]
        var members: [CompoundMemberPlan] = []
        var leafKeys: Set<String> = []

        for member in config.compoundMembers {
            if processHandle?.isCancelled == true {
                throw IdeaLightRunError.launchCancelled(detail: "Compound 启动已被用户停止。")
            }
            let referenced: RunConfiguration
            switch ConfigurationReferenceResolver.resolve(
                name: member.name,
                type: member.type.isEmpty ? nil : member.type,
                in: scan.configurations,
                allowNameFallback: true
            ) {
            case .found(let found):
                referenced = found
            case .notFound:
                throw IdeaLightRunError.referencedConfigurationNotFound(
                    detail: "Compound 配置 “\(config.name)” 引用了 “\(member.name)”，但当前项目里没有这个运行配置。"
                )
            case .typeMismatch:
                throw IdeaLightRunError.referencedConfigurationNotFound(
                    detail: "Compound 配置 “\(config.name)” 引用了 “\(member.name)”（类型 \(member.type)），"
                        + "项目里存在同名配置但类型不匹配。请检查 IDEA 中的引用。"
                )
            }
            if chain.contains(referenced.name) {
                throw IdeaLightRunError.beforeLaunchCycle(chain: chain + [referenced.name])
            }

            log(LogLine(
                stream: .system,
                text: "[IdeaLightRun] Compound 成员：\(referenced.name)（\(referenced.type.displayName)）"
            ))
            progress(.preparing)
            let execution = try await prepareResolved(
                config: referenced,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                log: log,
                progress: progress,
                processHandle: processHandle,
                gateOwner: gateOwner,
                visiting: chain
            )

            let leaves: [CompoundMemberPlan]
            if case .compound(let nested) = execution {
                leaves = nested.members
            } else {
                leaves = [CompoundMemberPlan(
                    name: referenced.name,
                    configurationKey: referenced.uniqueKey,
                    execution: execution
                )]
            }
            for leaf in leaves {
                guard leafKeys.insert(leaf.configurationKey).inserted else {
                    throw IdeaLightRunError.invalidConfiguration(
                        detail: "Compound 配置 “\(config.name)” 重复引用了 “\(leaf.name)”。"
                            + "同一配置一次启动只能出现一次。"
                    )
                }
                members.append(leaf)
            }
        }

        guard !members.isEmpty else {
            throw IdeaLightRunError.invalidConfiguration(detail: "配置 “\(config.name)” 没有可启动的成员。")
        }
        if processHandle?.isCancelled == true {
            throw IdeaLightRunError.launchCancelled(detail: "Compound 启动已被用户停止。")
        }
        progress(.starting)
        return .compound(CompoundExecutionPlan(name: config.name, members: members))
    }

    // MARK: - JAR Application

    /// §5: JAR 不要求 Main Class、项目 classpath 或构建系统本身。
    /// Module 仅用于 `$MODULE_DIR$` 与 Before Launch 的 Build；
    /// 只有出现构建类任务时才解析 Maven 工具链。
    private func prepareJar(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider,
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
        let needsToolchain = tasks.contains { task in
            switch task.kind {
            case .build, .buildProject, .mavenGoal, .gradleTask:
                return true
            case .runConfiguration, .unknown:
                return false
            }
        }

        let toolchain: ProjectToolchain?
        if needsToolchain {
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
                                    + "需要可解析的 Module 与可用的 Maven / Gradle 项目。"
                            )
                        }
                        progress(.building)
                        let target = toolchain.target(
                            for: module,
                            includeProvided: config.includeProvidedDependencies
                        )
                        try toolchain.adapter.buildModule(target, handle: processHandle, log: log)
                    },
                    buildProject: {
                        guard let toolchain else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 的 Before Launch 需要 Build Project，但当前项目无法确定构建系统。"
                            )
                        }
                        progress(.building)
                        try toolchain.adapter.buildProject(kind: .build, handle: processHandle, log: log)
                    },
                    runMavenGoals: { goals, pomFile in
                        guard let toolchain else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 的 Before Launch 需要 Maven，但当前项目无法使用 Maven。"
                            )
                        }
                        guard toolchain.kind == .maven else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 的 Before Launch 包含 Maven 任务，"
                                    + "但当前项目使用 \(toolchain.kind.displayName) 构建。"
                            )
                        }
                        progress(.building)
                        try toolchain.adapter.runTasks(
                            goals,
                            pomFile: pomFile,
                            moduleDirectory: module?.directory ?? projectRoot,
                            handle: processHandle,
                            log: log
                        )
                    },
                    runGradleTasks: { tasks in
                        guard let toolchain else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 的 Before Launch 需要 Gradle，但当前项目无法使用 Gradle。"
                            )
                        }
                        guard toolchain.kind == .gradle else {
                            throw IdeaLightRunError.unsupportedBeforeLaunch(
                                detail: "配置 “\(config.name)” 的 Before Launch 包含 Gradle 任务，"
                                    + "但当前项目使用 \(toolchain.kind.displayName) 构建。"
                            )
                        }
                        progress(.building)
                        try toolchain.adapter.runTasks(
                            tasks,
                            pomFile: nil,
                            moduleDirectory: module?.directory ?? projectRoot,
                            handle: processHandle,
                            log: log
                        )
                    },
                    runReferenced: { referenced, chain in
                        let referencedExecution = try await self.prepareResolved(
                            config: referenced,
                            projectRoot: projectRoot,
                            scan: scan,
                            hotReloadConfigurationFor: hotReloadConfigurationFor,
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

    // MARK: - Maven 运行配置

    /// MavenRunConfigurationType：直接执行配置保存的 goals。
    /// Maven 配置不要求选中 Module（`-pl` 由配置自己表达），Module 只在
    /// Before Launch 的 Build 与 `$MODULE_DIR$` 解析时才需要。
    private func prepareMaven(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        gateOwner: BuildGate.Owner?,
        visiting: [String]
    ) async throws -> PreparedExecution {
        let module = try Self.resolveModuleIfSpecified(
            config: config,
            projectRoot: projectRoot,
            knownModules: scan.modules
        )
        let toolchain = try ProjectToolchain.resolve(
            projectRoot: projectRoot,
            result: scan,
            config: config,
            configJDKName: config.jreReference,
            context: "启动",
            log: log
        )
        guard toolchain.kind == .maven else {
            throw IdeaLightRunError.buildToolNotFound(
                detail: "Maven 运行配置要求项目根存在 pom.xml，当前项目使用 \(toolchain.kind.displayName) 构建。"
            )
        }

        let owner = gateOwner ?? BuildGate.Owner()
        return try await BuildGate.shared.run(projectKey: projectRoot.standardizedFileURL.path, owner: owner) {
            let target = module.map {
                toolchain.target(for: $0, includeProvided: config.includeProvidedDependencies)
            }
            try await self.runBeforeLaunch(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                toolchain: toolchain,
                module: module,
                target: target,
                progress: progress,
                processHandle: processHandle,
                owner: owner,
                visiting: visiting,
                log: log
            )

            progress(.starting)
            let resolved = try RunConfigurationResolver().resolve(
                config: config,
                projectRoot: projectRoot,
                module: module,
                jdk: toolchain.jdk
            )
            Self.logResolvedConfiguration(resolved, log: log)
            let context = BuildInvocationContext(
                environment: resolved.environment,
                workingDirectory: resolved.workingDirectory
            )
            let plan = try toolchain.adapter.mavenExecution(
                config,
                module: module,
                context: context,
                log: log
            )
            return .process(plan)
        }
    }

    // MARK: - JUnit

    /// JUnit 配置必须在某个 Module 内运行；构建系统由项目本身决定
    /// （Maven → Surefire，Gradle → `:module:test`），命令由适配器生成。
    private func prepareJUnit(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        gateOwner: BuildGate.Owner?,
        visiting: [String]
    ) async throws -> PreparedExecution {
        let moduleResolution = ModuleResolver.resolveModule(
            named: config.moduleName,
            mainClass: nil,
            projectRoot: projectRoot,
            knownModules: scan.modules
        )
        guard let module = moduleResolution.module else {
            let detail = moduleResolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.moduleNotFound(
                detail: detail.isEmpty ? "JUnit 配置没有可选择 Module。" : detail
            )
        }

        let toolchain = try ProjectToolchain.resolve(
            projectRoot: projectRoot,
            result: scan,
            config: config,
            configJDKName: config.jreReference,
            context: "运行测试",
            log: log
        )
        let owner = gateOwner ?? BuildGate.Owner()
        return try await BuildGate.shared.run(projectKey: projectRoot.standardizedFileURL.path, owner: owner) {
            let target = toolchain.target(
                for: module,
                includeProvided: config.includeProvidedDependencies
            )
            try await self.runBeforeLaunch(
                config: config,
                projectRoot: projectRoot,
                scan: scan,
                hotReloadConfigurationFor: hotReloadConfigurationFor,
                toolchain: toolchain,
                module: module,
                target: target,
                progress: progress,
                processHandle: processHandle,
                owner: owner,
                visiting: visiting,
                log: log
            )

            progress(.starting)
            let resolved = try RunConfigurationResolver().resolve(
                config: config,
                projectRoot: projectRoot,
                module: module,
                jdk: toolchain.jdk
            )
            Self.logResolvedConfiguration(resolved, log: log)
            let context = BuildInvocationContext(
                environment: resolved.environment,
                workingDirectory: resolved.workingDirectory
            )
            let plan = try toolchain.adapter.testExecution(
                config,
                module: module,
                context: context,
                log: log
            )
            return .test(plan)
        }
    }

    /// Maven / JUnit 共用的 Before Launch 执行：动作语义与 Java 启动一致，
    /// 但两者都不做 classpath 解析，因此 Build 就是一次真实编译。
    private func runBeforeLaunch(
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        hotReloadConfigurationFor: @escaping HotReloadConfigurationProvider,
        toolchain: ProjectToolchain,
        module: ProjectModule?,
        target: BuildTarget?,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle?,
        owner: BuildGate.Owner,
        visiting: [String],
        log: @escaping LogCallback
    ) async throws {
        try await BeforeLaunchExecutor().run(
            for: config,
            configurations: scan.configurations,
            actions: BeforeLaunchExecutor.Actions(
                build: {
                    guard let target else {
                        throw IdeaLightRunError.unsupportedBeforeLaunch(
                            detail: "配置 “\(config.name)” 的 Before Launch 需要 Build，"
                                + "但没有可解析的 Module。请在 IDEA 中为该配置选择 Module。"
                        )
                    }
                    progress(.building)
                    try toolchain.adapter.buildModule(target, handle: processHandle, log: log)
                },
                buildProject: {
                    progress(.building)
                    try toolchain.adapter.buildProject(kind: .build, handle: processHandle, log: log)
                },
                runMavenGoals: { goals, pomFile in
                    guard toolchain.kind == .maven else {
                        throw IdeaLightRunError.unsupportedBeforeLaunch(
                            detail: "配置 “\(config.name)” 的 Before Launch 包含 Maven 任务，"
                                + "但当前项目使用 \(toolchain.kind.displayName) 构建。"
                        )
                    }
                    progress(.building)
                    try toolchain.adapter.runTasks(
                        goals,
                        pomFile: pomFile,
                        moduleDirectory: module?.directory ?? projectRoot,
                        handle: processHandle,
                        log: log
                    )
                },
                runGradleTasks: { tasks in
                    guard toolchain.kind == .gradle else {
                        throw IdeaLightRunError.unsupportedBeforeLaunch(
                            detail: "配置 “\(config.name)” 的 Before Launch 包含 Gradle 任务，"
                                + "但当前项目使用 \(toolchain.kind.displayName) 构建。"
                        )
                    }
                    progress(.building)
                    try toolchain.adapter.runTasks(
                        tasks,
                        pomFile: nil,
                        moduleDirectory: module?.directory ?? projectRoot,
                        handle: processHandle,
                        log: log
                    )
                },
                runReferenced: { referenced, chain in
                    let referencedExecution = try await self.prepareResolved(
                        config: referenced,
                        projectRoot: projectRoot,
                        scan: scan,
                        hotReloadConfigurationFor: hotReloadConfigurationFor,
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
    }

    // MARK: - 能力门禁（§23/§P0-5）

    /// 运行类型判断留在 Core：GUI / CLI 不许自己 `if Maven`、`if SpringBoot`。
    /// 可运行性由 `ConfigurationCapabilityResolver` 统一计算，界面徽标与门禁同源。
    static func ensureRunnable(_ config: RunConfiguration) throws {
        try ensureRunnable(ConfigurationCapabilityResolver.resolve(config), for: config)
    }

    /// 项目感知门禁：构建系统缺失时沿用 `buildToolNotFound` 的既有语义，
    /// 让调用方拿到明确的工具链原因；Maven / Gradle 都缺失才算缺工具链，
    /// 其余阻断（缺 Module、Before Launch 类型不匹配）按配置问题报告。
    /// JAR Application 不需要构建系统本身，缺失原因（JAR Path / Before Launch）按配置错误报告。
    static func ensureRunnable(_ config: RunConfiguration, scan: ScanResult) throws {
        let capability = ConfigurationCapabilityResolver.resolve(config, scan: scan)
        guard !capability.isLaunchable else { return }
        switch config.type {
        case .application, .springBoot, .maven, .junit:
            if capability.buildSystem == nil {
                throw IdeaLightRunError.buildToolNotFound(
                    detail: capability.primaryReason ?? "无法确定项目的构建系统。"
                )
            }
        default:
            break
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
                + " 现在能替代 IDEA Run 按钮的是 Application、Spring Boot、JAR Application、"
                + "Maven、JUnit 与 Compound 配置。"
        )
    }

    // MARK: - 内部

    /// Maven 配置的 Module 是可选的；只有显式写了 module 名却找不到时才报错，
    /// 不能因为没选 Module 就阻止 `mvn` 本身执行。
    private static func resolveModuleIfSpecified(
        config: RunConfiguration,
        projectRoot: URL,
        knownModules: [ProjectModule]
    ) throws -> ProjectModule? {
        let name = config.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let resolution = ModuleResolver.resolveModule(
            named: name,
            mainClass: nil,
            projectRoot: projectRoot,
            knownModules: knownModules
        )
        guard let module = resolution.module else {
            let detail = resolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.moduleNotFound(detail: detail.isEmpty ? "找不到 Module “\(name)”。" : detail)
        }
        return module
    }

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
