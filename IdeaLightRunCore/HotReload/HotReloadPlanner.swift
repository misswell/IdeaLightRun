import Foundation

/// 一个 JVM 的热更新计划。它同时携带“编译谁”和“把哪些类交给 Agent”，
/// 进程执行器不需要知道 Maven / Gradle / Spring Boot 的差别。
public struct HotReloadLaunchPlan: Sendable {
    public var configuration: HotReloadConfiguration
    public var configName: String
    public var provider: HotReloadProviderKind
    public var capability: HotReloadCapability
    public var workspace: HotReloadWorkspace
    public var adapter: any BuildSystemAdapter
    public var projectKey: String
    /// 内置 Agent 的启动参数；DevTools / 外部 Agent 为空。
    public var agentLaunch: HotReloadAgentLaunch?
    /// 追加到 JVM 命令行的参数（仅 Agent 相关，不包含用户的 VM Options）。
    public var extraJVMArguments: [String]
    /// 非空表示热更新本次无法真正生效（Agent 缺失 / DevTools 不在 classpath 等）。
    public var agentInitProblem: String?
    public var notes: [String]

    public init(
        configuration: HotReloadConfiguration,
        configName: String,
        provider: HotReloadProviderKind,
        capability: HotReloadCapability,
        workspace: HotReloadWorkspace,
        adapter: any BuildSystemAdapter,
        projectKey: String,
        agentLaunch: HotReloadAgentLaunch? = nil,
        extraJVMArguments: [String] = [],
        agentInitProblem: String? = nil,
        notes: [String] = []
    ) {
        self.configuration = configuration
        self.configName = configName
        self.provider = provider
        self.capability = capability
        self.workspace = workspace
        self.adapter = adapter
        self.projectKey = projectKey
        self.agentLaunch = agentLaunch
        self.extraJVMArguments = extraJVMArguments
        self.agentInitProblem = agentInitProblem
        self.notes = notes
    }

    public var usesBuiltInAgent: Bool {
        provider == .standard && agentLaunch != nil && agentInitProblem == nil
    }

    /// DevTools / 外部 Agent 自己决定何时重载，IdeaLightRun 只负责编译与报告。
    public var delegatesApply: Bool {
        provider != .standard
    }
}

public enum HotReloadPlanner {
    /// 只对直接启动 JVM 的 Application / Spring Boot 配置生效。
    /// Maven / JUnit / JAR 的类型门禁仍由 `ExecutionCoordinator` 负责，
    /// 这里返回 nil 表示“本次启动不注入热更新”，并在日志里说明原因。
    public static func makePlan(
        configuration rawConfiguration: HotReloadConfiguration,
        config: RunConfiguration,
        projectRoot: URL,
        scan: ScanResult,
        module: ProjectModule,
        classpath: [String],
        adapter: any BuildSystemAdapter,
        includeProvided: Bool,
        log: @escaping (String) -> Void
    ) -> HotReloadLaunchPlan? {
        guard rawConfiguration.isActive else { return nil }
        guard config.type == .application || config.type == .springBoot else {
            log("[HotReload] “\(config.name)” 是 \(config.type.displayName) 配置；热更新目前只支持直接启动 JVM 的 Application / Spring Boot 配置。")
            return nil
        }

        let configuration = rawConfiguration.normalized
        let devToolsDetected = detectSpringBootDevTools(classpath: classpath)
        let provider = resolveProvider(configuration.provider, devToolsDetected: devToolsDetected)
        let capability = provider.staticCapability
        var notes: [String] = []
        var extraJVMArguments: [String] = []
        var agentLaunch: HotReloadAgentLaunch?
        var agentInitProblem: String?

        switch provider {
        case .standard:
            if let jar = HotReloadAgentLocator.locate() {
                do {
                    let launch = try HotReloadAgentLaunch.prepare(jarURL: jar)
                    agentLaunch = launch
                    extraJVMArguments.append(contentsOf: launch.jvmArguments)
                } catch {
                    agentInitProblem = (error as? IdeaLightRunError)?.localizedDescription
                        ?? error.localizedDescription
                }
            } else {
                agentInitProblem = "找不到内置 HotReloadAgent.jar。请确认应用包里包含 Resources/HotReloadAgent.jar"
                    + "（开发期可用环境变量 \(HotReloadAgentLocator.environmentKey) 指向本地构建产物）。"
            }
            if devToolsDetected {
                notes.append("检测到 spring-boot-devtools：它也可能因 classpath 变化触发快速重启；"
                    + "如果只想用 DevTools，请把后端切换为 Spring Boot DevTools。")
            }

        case .springBootDevTools:
            if !devToolsDetected {
                agentInitProblem = "runtime classpath 中没有 spring-boot-devtools，DevTools 快速重启不会生效。"
                    + "请先在项目中加入 devtools 依赖，或改用内置 HotSwap。"
            }
            notes.append("DevTools 是快速重启，不是方法体热替换；编译成功后状态会标为“已交给外部后端”。")

        case .hotswapAgent, .jrebel:
            let rawPath = configuration.externalAgentPath?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let arguments = splitArguments(configuration.externalAgentArguments)
            let hasAgentArgument = arguments.contains { $0.hasPrefix("-javaagent:") }
            var resolvedPath: URL?
            if !rawPath.isEmpty {
                let expanded = (rawPath as NSString).expandingTildeInPath
                let url = expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded)
                    : projectRoot.appendingPathComponent(expanded)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    resolvedPath = url
                    if isDirectory.boolValue {
                        if !hasAgentArgument {
                            agentInitProblem = "外部 Agent 路径指向目录：请在“外部 Agent 参数”里提供完整的 "
                                + "-javaagent:<jar> 参数。"
                        }
                    } else if !hasAgentArgument {
                        extraJVMArguments.append("-javaagent:\(url.path)")
                    }
                } else {
                    agentInitProblem = "外部 Agent 路径不存在：\(url.path)"
                }
            } else if !hasAgentArgument {
                agentInitProblem = "已选择外部 Agent 后端，但没有配置 Agent 路径或 -javaagent 参数。"
            }
            if resolvedPath != nil, hasAgentArgument {
                // 用户自己给出了 -javaagent，不再重复注入；路径只用于存在性校验。
                notes.append("外部 Agent 参数由你提供；IdeaLightRun 不验证其版本、授权与热更新结果。")
            }
            extraJVMArguments.append(contentsOf: arguments)
            notes.append("外部 Agent 的能力由它自己决定；状态只会标为“已交给外部后端”。")
        case .automatic:
            break
        }

        let workspace = HotReloadWorkspace.make(
            projectRoot: projectRoot,
            scan: scan,
            primaryModule: module,
            adapter: adapter,
            includeProvided: includeProvided,
            classpath: classpath,
            configuration: configuration
        )

        if workspace.outputRoots.isEmpty, agentInitProblem == nil {
            agentInitProblem = "runtime classpath 中没有项目内的输出目录，无法把编译结果映射到可重定义的类。"
        }
        if workspace.moduleWatches.allSatisfy({ $0.allRoots.isEmpty }), agentInitProblem == nil {
            notes.append("未发现标准源码目录（src/main/java|kotlin|groovy|scala|resources）；"
                + "保存源码不会触发编译，但仍会监听外部构建产物。")
        }
        if workspace.moduleWatches.count > 1 {
            notes.append("监听 \(workspace.moduleWatches.count) 个模块；共享模块变更会编译该模块并应用到依赖它的运行实例。")
        }
        if configuration.watchCompiledOutputs {
            notes.append("同时监听 runtime classpath 中的项目输出目录，兼容 IDEA / 命令行的外部构建。")
        }
        if let problem = agentInitProblem {
            notes.append("热更新未就绪：\(problem)")
        }

        return HotReloadLaunchPlan(
            configuration: configuration,
            configName: config.name,
            provider: provider,
            capability: capability,
            workspace: workspace,
            adapter: adapter,
            projectKey: projectRoot.standardizedFileURL.path,
            agentLaunch: agentLaunch,
            extraJVMArguments: extraJVMArguments,
            agentInitProblem: agentInitProblem,
            notes: notes
        )
    }

    static func resolveProvider(
        _ configured: HotReloadProviderKind,
        devToolsDetected: Bool
    ) -> HotReloadProviderKind {
        switch configured {
        case .automatic:
            // DevTools 会在 classpath 变化时自行快速重启，和内置 Agent 抢同一批变更；
            // 检测到 devtools 时自动选它，避免“以为在热替换、实际被重启”的假象。
            return devToolsDetected ? .springBootDevTools : .standard
        case .standard, .springBootDevTools, .hotswapAgent, .jrebel:
            return configured
        }
    }

    public static func detectSpringBootDevTools(classpath: [String]) -> Bool {
        classpath.contains { entry in
            entry.lowercased().contains("spring-boot-devtools")
        }
    }

    /// 外部 Agent 参数按空白分词；支持单/双引号与反斜杠转义，
    /// 但绝不会把它交给 shell 执行（§27）。
    public static func splitArguments(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasContent = false

        for character in raw {
            if escaping {
                current.append(character)
                hasContent = true
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasContent = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasContent = true
                continue
            }
            if character.isWhitespace {
                if hasContent {
                    result.append(current)
                    current = ""
                    hasContent = false
                }
                continue
            }
            current.append(character)
            hasContent = true
        }
        if hasContent {
            result.append(current)
        }
        return result
    }
}
