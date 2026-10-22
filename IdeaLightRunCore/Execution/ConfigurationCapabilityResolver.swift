import Foundation

/// §P0-5: 一个配置“能不能跑”只在这里计算。Core 的门禁、GUI 徽标与 CLI 输出
/// 都消费同一个结果，禁止界面侧再写一份 `if type == .springBoot`。
///
/// 结果不仅取决于运行配置类型，还取决于项目构建系统、配置字段、
/// Before Launch 任务和引用完整性；没有扫描结果时只能给出类型/字段级结论。
public struct ConfigurationCapability: Equatable, Sendable {
    public enum IssueKind: String, Equatable, Sendable {
        /// 阻止启动。
        case blocking
        /// 可以启动，但需要用户知道。
        case warning
    }

    public struct Issue: Equatable, Sendable {
        public var kind: IssueKind
        public var message: String

        public init(kind: IssueKind, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    public var readiness: Readiness
    public var issues: [Issue]
    public var missingFields: [String]
    public var unsupportedBeforeLaunchTasks: [String]
    /// 项目级构建系统选择结果；未扫描或无法判断时为 nil。
    public var buildSystem: BuildSystemKind?

    public init(
        readiness: Readiness,
        issues: [Issue] = [],
        missingFields: [String] = [],
        unsupportedBeforeLaunchTasks: [String] = [],
        buildSystem: BuildSystemKind? = nil
    ) {
        self.readiness = readiness
        self.issues = issues
        self.missingFields = missingFields
        self.unsupportedBeforeLaunchTasks = unsupportedBeforeLaunchTasks
        self.buildSystem = buildSystem
    }

    public var blockingIssues: [String] {
        issues.filter { $0.kind == .blocking }.map(\.message)
    }

    public var warningIssues: [String] {
        issues.filter { $0.kind == .warning }.map(\.message)
    }

    public var primaryReason: String? {
        blockingIssues.first ?? warningIssues.first
    }

    public var isLaunchable: Bool {
        readiness == .ready || readiness == .warning
    }
}

public enum ConfigurationCapabilityResolver {
    /// 无扫描上下文：只检查类型与配置自身字段。
    public static func resolve(_ config: RunConfiguration) -> ConfigurationCapability {
        resolve(config, scan: nil)
    }

    /// 带扫描上下文：额外检查构建系统、Before Launch 引用与项目工具链。
    public static func resolve(_ config: RunConfiguration, scan: ScanResult) -> ConfigurationCapability {
        resolve(config, scan: Optional(scan))
    }

    public static func resolveAll(in scan: ScanResult) -> [String: ConfigurationCapability] {
        var result: [String: ConfigurationCapability] = [:]
        for config in scan.configurations {
            result[config.uniqueKey] = resolve(config, scan: scan)
        }
        return result
    }

    private static func resolve(_ config: RunConfiguration, scan: ScanResult?) -> ConfigurationCapability {
        switch config.type {
        case .compound:
            return terminal(.planned, "Compound 配置已识别；多配置启动将在 Milestone 3 接入，当前不能启动。")
        case .maven:
            return terminal(.planned, "Maven 运行配置已识别；直接运行 Maven goal 将在 Milestone 5 接入，当前不能启动。")
        case .gradle:
            return terminal(.planned, "Gradle 运行配置已识别；Gradle 构建与运行将在 Milestone 4 接入，当前不能启动。")
        case .junit:
            return terminal(.unsupported, "JUnit 测试运行尚未接入，当前不能启动。")
        case .unknown(let raw):
            let name = raw.isEmpty ? "（空类型）" : raw
            return terminal(.unsupported, "配置类型 “\(name)” 不在当前支持范围内。")
        case .application, .springBoot, .jar:
            break
        }

        var issues: [ConfigurationCapability.Issue] = []
        var missingFields: [String] = []
        var unsupportedTasks: [String] = []
        var buildSystem: BuildSystemKind?

        func block(_ message: String) {
            issues.append(ConfigurationCapability.Issue(kind: .blocking, message: message))
        }
        func warn(_ message: String) {
            issues.append(ConfigurationCapability.Issue(kind: .warning, message: message))
        }

        if config.type == .jar {
            let jarPath = config.jarPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if jarPath.isEmpty {
                missingFields.append("JAR Path")
                block("配置缺少 JAR Path，无法构造 java -jar 启动命令。")
            } else if let scan,
                      let resolved = Self.resolvedJarURL(jarPath, config: config, scan: scan) {
                // IDEA 的 checkConfiguration 对不存在的 JAR 只给 warning：
                // Before Launch 可能先生成产物。存在性最终由 JarRunPlanner 在构建后校验。
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    warn("JAR 文件当前不存在：\(resolved.path)。如果它由 Before Launch 生成，可忽略此提示。")
                } else if !FileManager.default.isReadableFile(atPath: resolved.path) {
                    block("JAR 文件不可读取：\(resolved.path)")
                }
            }
        } else {
            let mainClass = config.mainClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if mainClass.isEmpty {
                missingFields.append("Main Class")
                block("配置缺少 Main Class，无法构造 java 启动命令。")
            }
        }

        for task in config.beforeLaunchTasks where task.isEnabled {
            switch task.kind {
            case .build, .buildProject:
                break
            case .mavenGoal(let goal, _):
                if CommandLineTokenizer.tokenize(goal).isEmpty {
                    missingFields.append("Maven goal")
                    block("Before Launch 的 Maven 任务没有保存 goal，无法确定要执行什么。")
                }
            case .gradleTask(let task):
                let display = task.trimmingCharacters(in: .whitespacesAndNewlines)
                unsupportedTasks.append(display.isEmpty ? "Gradle（未命名任务）" : "Gradle: \(display)")
                block("Before Launch 的 Gradle 任务“\(display)”尚未接入，IdeaLightRun 不会静默跳过它。")
            case .runConfiguration(let name, let type):
                if let scan, !referenceExists(name: name, type: type, in: scan.configurations) {
                    block("Before Launch 引用的配置 “\(name)” 不存在或类型不匹配。")
                }
            case .unknown(let raw):
                unsupportedTasks.append(raw)
                block("Before Launch 任务 “\(raw)” 暂不支持执行。")
            }
        }

        for warning in config.warnings {
            switch warning {
            case .missingMainClass, .missingJarPath, .unsupportedBeforeLaunch:
                // 已由上面的阻断项覆盖，避免同一条问题出现两次。
                continue
            default:
                warn("\(warning.title)：\(warning.detail)")
            }
        }

        if let scan {
            let selection = BuildSystemSelector.select(
                config: config,
                detection: scan.buildSystem,
                modules: scan.modules
            )
            buildSystem = selection.kind
            if config.type == .jar {
                if selection.isAmbiguous {
                    warn(selection.reason)
                }
                let enabledTasks = config.beforeLaunchTasks.filter(\.isEnabled)
                let needsMaven = enabledTasks.contains { task in
                    switch task.kind {
                    case .build, .buildProject, .mavenGoal:
                        return true
                    case .runConfiguration, .gradleTask, .unknown:
                        return false
                    }
                }
                if needsMaven {
                    if selection.kind != .maven {
                        block("JAR 配置的 Before Launch 包含 Maven 构建任务，但当前项目无法使用 Maven：\(selection.reason)")
                    } else if enabledTasks.contains(where: { task in
                        if case .build = task.kind { return true }
                        return false
                    }) {
                        let moduleName = config.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let resolution = ModuleResolver.resolveModule(
                            named: moduleName.isEmpty ? nil : moduleName,
                            mainClass: nil,
                            projectRoot: scan.projectRoot,
                            knownModules: scan.modules
                        )
                        if resolution.module == nil {
                            block("JAR 配置的 Before Launch Build 需要可解析的 Module；请在 IDEA 的运行配置里选择 Module。")
                        }
                    }
                }
            } else {
                switch selection.kind {
                case .maven:
                    if selection.isAmbiguous {
                        warn(selection.reason)
                    }
                    if let moduleName = config.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !moduleName.isEmpty,
                       !scan.modules.isEmpty {
                        let resolution = ModuleResolver.resolveModule(
                            named: moduleName,
                            mainClass: config.mainClass,
                            projectRoot: scan.projectRoot,
                            knownModules: scan.modules
                        )
                        if let module = resolution.module {
                            if resolution.method == .byMainClassFallback {
                                warn("找不到 Module “\(moduleName)”，已按 Main Class 定位到 \(module.directory.path)。")
                            }
                        } else {
                            block("找不到 Module “\(moduleName)”，启动时无法定位编译产物与 classpath。")
                        }
                    }
                case .gradle:
                    return terminal(
                        .planned,
                        "检测到 Gradle 项目；Gradle 构建与 classpath 解析将在 Milestone 4 接入，当前不能启动。",
                        buildSystem: .gradle
                    )
                case nil:
                    block(selection.reason)
                }
            }
        }

        let readiness: Readiness
        if issues.contains(where: { $0.kind == .blocking }) {
            readiness = .unsupported
        } else if issues.contains(where: { $0.kind == .warning }) {
            readiness = .warning
        } else {
            readiness = .ready
        }

        return ConfigurationCapability(
            readiness: readiness,
            issues: issues,
            missingFields: missingFields,
            unsupportedBeforeLaunchTasks: unsupportedTasks,
            buildSystem: buildSystem
        )
    }

    private static func terminal(
        _ readiness: Readiness,
        _ message: String,
        buildSystem: BuildSystemKind? = nil
    ) -> ConfigurationCapability {
        ConfigurationCapability(
            readiness: readiness,
            issues: [ConfigurationCapability.Issue(kind: .blocking, message: message)],
            buildSystem: buildSystem
        )
    }

    /// 只做“无需环境文件即可确定”的路径检查：出现未解析变量时返回 nil，
    /// 把最终判断留给启动前的 `JarRunPlanner`，避免误报。
    private static func resolvedJarURL(
        _ raw: String,
        config: RunConfiguration,
        scan: ScanResult
    ) -> URL? {
        let module = ModuleResolver.resolveModule(
            named: config.moduleName,
            mainClass: nil,
            projectRoot: scan.projectRoot,
            knownModules: scan.modules
        ).module
        let resolution = MacroResolver(
            projectDir: scan.projectRoot,
            moduleDir: module?.directory
        ).resolve(raw)
        guard resolution.warnings.isEmpty else { return nil }
        let value = resolution.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return RunConfigurationResolver.fileURL(for: value, projectRoot: scan.projectRoot)
    }

    private static func referenceExists(
        name: String,
        type: String?,
        in configurations: [RunConfiguration]
    ) -> Bool {
        let sameName = configurations.filter { $0.name == name }
        if let type, !type.isEmpty {
            return sameName.contains { $0.type.ideaTypeRaw == type }
        }
        return !sameName.isEmpty
    }
}
