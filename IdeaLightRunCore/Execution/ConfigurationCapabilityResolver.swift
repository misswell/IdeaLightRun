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
        resolve(config, scan: scan, visiting: [])
    }

    private static func resolve(
        _ config: RunConfiguration,
        scan: ScanResult?,
        visiting: [String]
    ) -> ConfigurationCapability {
        switch config.type {
        case .compound:
            return resolveCompound(config, scan: scan, visiting: visiting)
        case .gradle:
            return terminal(.planned, "Gradle 运行配置（直接执行 Gradle 任务）已识别；该类型尚未接入，当前不能启动。")
        case .unknown(let raw):
            let name = raw.isEmpty ? "（空类型）" : raw
            return terminal(.unsupported, "配置类型 “\(name)” 不在当前支持范围内。")
        case .maven, .junit, .application, .springBoot, .jar:
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
        } else if config.type == .maven {
            if let options = config.mavenOptions {
                let goals = options.goals.flatMap { CommandLineTokenizer.tokenize($0) }
                if goals.isEmpty {
                    missingFields.append("Maven goals")
                    block("Maven 配置没有保存任何 goal，无法确定要执行什么。")
                }
                if !options.unsupportedOptions.isEmpty {
                    block("Maven 配置使用了暂不支持的选项："
                        + options.unsupportedOptions.joined(separator: "、")
                        + "。请在 IDEA 中改回默认设置，或用 Maven goal 表达同样的语义。")
                }
                if !options.jreName.isEmpty,
                   options.jreName != "#USE_PROJECT_JDK",
                   options.jreName != "#JAVA_HOME" {
                    block("Maven 配置指定的 JRE “\(options.jreName)” 暂不支持；请改用 Project JDK 或 JAVA_HOME。")
                }
            } else {
                block("Maven 配置缺少运行参数。")
            }
        } else if config.type == .junit {
            if let options = config.junitOptions {
                switch options.target {
                case .unsupported(let reason):
                    block("JUnit 测试目标不可用：\(reason)")
                case .tags:
                    block("JUnit Tag 筛选暂不支持；请在 IDEA 中改用类、方法、包或目录作为测试目标。")
                case .uniqueId:
                    block("JUnit Unique ID 定位暂不支持；请在 IDEA 中改用类、方法、包或目录作为测试目标。")
                default:
                    break
                }
                if !options.programArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    block("JUnit 配置设置了 Program Arguments；Surefire / Gradle Test 没有等价的程序参数入口，当前不能运行。")
                }
            } else {
                block("JUnit 配置缺少测试目标。")
            }
            let moduleName = config.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if moduleName.isEmpty {
                missingFields.append("Module")
                block("JUnit 配置必须选择 Module，测试类与工作目录都相对模块定位。")
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
                if display.isEmpty || CommandLineTokenizer.tokenize(task).isEmpty {
                    missingFields.append("Gradle task")
                    block("Before Launch 的 Gradle 任务没有保存任务名，无法确定要执行什么。")
                }
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
            let enabledTasks = config.beforeLaunchTasks.filter(\.isEnabled)
            let hasMavenTask = enabledTasks.contains { task in
                if case .mavenGoal = task.kind { return true }
                return false
            }
            let hasGradleTask = enabledTasks.contains { task in
                if case .gradleTask = task.kind { return true }
                return false
            }
            let needsBuildToolchain = enabledTasks.contains { task in
                switch task.kind {
                case .build, .buildProject, .mavenGoal, .gradleTask:
                    return true
                case .runConfiguration, .unknown:
                    return false
                }
            }

            if config.type == .jar {
                if selection.isAmbiguous {
                    warn(selection.reason)
                }
                if hasMavenTask, selection.kind != .maven {
                    block("JAR 配置的 Before Launch 包含 Maven 任务，但当前项目无法使用 Maven：\(selection.reason)")
                }
                if hasGradleTask, selection.kind != .gradle {
                    block("JAR 配置的 Before Launch 包含 Gradle 任务，但当前项目无法使用 Gradle：\(selection.reason)")
                }
                if needsBuildToolchain, selection.kind == nil {
                    block("JAR 配置的 Before Launch 需要构建系统，但当前项目无法确定构建系统：\(selection.reason)")
                }
                if enabledTasks.contains(where: { task in
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
            } else {
                switch selection.kind {
                case .maven, .gradle:
                    if selection.isAmbiguous {
                        warn(selection.reason)
                    }
                    // 构建系统与 Before Launch 任务类型必须一致：把 Maven goal 交给
                    // Gradle 执行（或反之）会静默改变任务语义。
                    if hasGradleTask, selection.kind == .maven {
                        block("Before Launch 的 Gradle 任务需要 Gradle，但当前项目使用 Maven。请改用 Maven Goal，或在 IDEA 中停用该任务。")
                    }
                    if hasMavenTask, selection.kind == .gradle {
                        block("Before Launch 的 Maven 任务需要 Maven，但当前项目使用 Gradle。请改用 Gradle 任务，或在 IDEA 中停用该任务。")
                    }
                    if config.type == .junit {
                        let resolution = ModuleResolver.resolveModule(
                            named: config.moduleName,
                            mainClass: nil,
                            projectRoot: scan.projectRoot,
                            knownModules: scan.modules
                        )
                        if let module = resolution.module {
                            if selection.kind == .maven,
                               let mismatch = junitWorkingDirectoryMismatch(
                                   config: config,
                                   module: module,
                                   projectRoot: scan.projectRoot
                               ) {
                                block(mismatch)
                            }
                        } else {
                            let moduleName = config.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            block("找不到 JUnit 配置的 Module “\(moduleName)”，测试类与工作目录无法定位。")
                        }
                    } else if let moduleName = config.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    /// §Compound: 成员必须存在、类型一致、各自可启动；成员之间的嵌套引用也要查环。
    /// 组合配置自身没有 Main Class / JAR / 构建系统字段：它的可运行性完全由成员决定。
    private static func resolveCompound(
        _ config: RunConfiguration,
        scan: ScanResult?,
        visiting: [String]
    ) -> ConfigurationCapability {
        var issues: [ConfigurationCapability.Issue] = []
        var missingFields: [String] = []

        func block(_ message: String) {
            issues.append(ConfigurationCapability.Issue(kind: .blocking, message: message))
        }
        func warn(_ message: String) {
            issues.append(ConfigurationCapability.Issue(kind: .warning, message: message))
        }

        if !config.beforeLaunchTasks.filter(\.isEnabled).isEmpty {
            block("Compound 配置自身的 Before Launch 任务暂不支持执行；IdeaLightRun 不会跳过它们直接启动。请把构建等任务放到成员配置中。")
        }
        if config.compoundMembers.isEmpty {
            missingFields.append("Compound 成员")
            block("Compound 配置没有引用任何子配置，无法启动。")
        }

        if let scan {
            let chain = visiting + [config.uniqueKey]
            for member in config.compoundMembers {
                let reference = ConfigurationReferenceResolver.resolve(
                    name: member.name,
                    type: member.type.isEmpty ? nil : member.type,
                    in: scan.configurations,
                    allowNameFallback: true
                )
                switch reference {
                case .notFound:
                    block("Compound 成员 “\(member.name)” 不存在于当前项目。")
                case .typeMismatch:
                    block("Compound 成员 “\(member.name)” 存在同名配置，但类型与引用（\(member.type)）不匹配。")
                case .found(let referenced):
                    if chain.contains(referenced.uniqueKey) {
                        block("Compound 成员 “\(referenced.name)” 形成循环引用：\(displayChain(chain + [referenced.uniqueKey], scan: scan))")
                        continue
                    }
                    let memberCapability = resolve(referenced, scan: scan, visiting: chain)
                    if !memberCapability.isLaunchable {
                        let reason = memberCapability.primaryReason ?? "当前版本不能启动。"
                        block("Compound 成员 “\(referenced.name)”（\(referenced.type.displayName)）不能启动：\(reason)")
                    } else if let warning = memberCapability.primaryReason {
                        warn("Compound 成员 “\(referenced.name)” 有提示：\(warning)")
                    }
                }
            }

            // 嵌套 Compound 会被展开成叶子成员执行；跨层重复引用同一个配置
            // 在启动时会变成"同一配置启动两次"，必须在能力阶段就拦住。
            var leafKeys: Set<String> = []
            for leaf in flattenedMembers(of: config, scan: scan, visiting: visiting) {
                if !leafKeys.insert(leaf.uniqueKey).inserted {
                    block("Compound 配置重复引用了 “\(leaf.name)”（\(leaf.type.displayName)）。同一配置一次启动只能出现一次。")
                }
            }
        }

        for warning in config.warnings {
            if case .custom(let title, _) = warning, title == "Compound 配置为空", config.compoundMembers.isEmpty {
                continue
            }
            warn("\(warning.title)：\(warning.detail)")
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
            missingFields: missingFields
        )
    }

    /// 递归展开嵌套 Compound，只返回真正会启动进程的叶子配置。
    /// 缺失/类型不匹配/成环的引用由调用方的逐项检查报告，这里跳过。
    private static func flattenedMembers(
        of config: RunConfiguration,
        scan: ScanResult,
        visiting: [String]
    ) -> [RunConfiguration] {
        let chain = visiting + [config.uniqueKey]
        var result: [RunConfiguration] = []
        for member in config.compoundMembers {
            guard case .found(let referenced) = ConfigurationReferenceResolver.resolve(
                name: member.name,
                type: member.type.isEmpty ? nil : member.type,
                in: scan.configurations,
                allowNameFallback: true
            ) else { continue }
            guard !chain.contains(referenced.uniqueKey) else { continue }
            if referenced.type == .compound {
                result.append(contentsOf: flattenedMembers(of: referenced, scan: scan, visiting: chain))
            } else {
                result.append(referenced)
            }
        }
        return result
    }

    private static func displayChain(_ keys: [String], scan: ScanResult) -> String {
        keys.map { key in
            scan.configurations.first(where: { $0.uniqueKey == key })?.name ?? key
        }.joined(separator: " -> ")
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

    /// Surefire 的 fork 工作目录固定为模块 basedir，命令行没有可靠入口覆盖；
    /// 只对可静态判定的字面量路径提前阻断，含宏的路径留给适配器在启动前判定。
    private static func junitWorkingDirectoryMismatch(
        config: RunConfiguration,
        module: ProjectModule,
        projectRoot: URL
    ) -> String? {
        let raw = config.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, !raw.contains("$"), !raw.contains("%") else { return nil }
        let requested = RunConfigurationResolver.fileURL(for: raw, projectRoot: projectRoot)
            .standardizedFileURL.path
        let expected = module.directory.standardizedFileURL.path
        guard requested != expected else { return nil }
        return "JUnit 配置的 Working Directory 是 \(requested)，但 Maven Surefire 只能使用模块目录 \(expected)。"
            + "请在 IDEA 中把 Working Directory 改为模块目录后再运行。"
    }

    private static func referenceExists(
        name: String,
        type: String?,
        in configurations: [RunConfiguration]
    ) -> Bool {
        if case .found = ConfigurationReferenceResolver.resolve(name: name, type: type, in: configurations) {
            return true
        }
        return false
    }
}
