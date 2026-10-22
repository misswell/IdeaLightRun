import Foundation

/// §10: 已知字段 → 标准模型；未知字段 → rawOptions。字段名使用 alias 表，
/// 不假设某个字段永远只有一种写法。
public enum RunConfigurationMapper {
    static let mainClassAliases = ["MAIN_CLASS_NAME", "MAIN_CLASS", "SPRING_BOOT_MAIN_CLASS"]
    /// JetBrains `JarApplicationConfigurationBean.JAR_PATH`，不是 `PATH`。
    static let jarPathAliases = ["JAR_PATH"]
    static let vmAliases = ["VM_PARAMETERS", "VM_OPTIONS"]
    static let programArgumentsAliases = ["PROGRAM_PARAMETERS", "PROGRAM_ARGUMENTS"]
    static let workingDirectoryAliases = ["WORKING_DIRECTORY"]
    static let jreAliases = ["ALTERNATIVE_JRE_PATH"]
    static let jreEnabledAliases = ["ALTERNATIVE_JRE_PATH_ENABLED"]
    static let springProfilesAliases = ["ACTIVE_PROFILES"]
    static let includeProvidedAliases = ["INCLUDE_PROVIDED_SCOPE"]
    static let allowParallelAliases = ["ALLOW_PARALLEL_RUN_WITHIN_GROUP", "ALLOW_MULTIPLE_INSTANCES"]
    static let envFileAliases = ["ENV_FILES", "ENV_FILE_PATHS"]
    /// §4.2: IDEA 写 PASS_PARENT_ENVS，早期版本与插件里见过 PASS_PARENT_ENV。
    static let passParentEnvAliases = ["PASS_PARENT_ENVS", "PASS_PARENT_ENV"]

    public static func map(node: XMLElementNode, source: ConfigurationSource) -> RunConfiguration? {
        guard node.name == "configuration" else { return nil }
        // default="true" 是模板配置，不是可运行配置。
        if node.attribute("default") == "true" { return nil }

        let name = node.attribute("name") ?? ""
        guard !name.isEmpty else { return nil }
        let type = RunConfigurationType.from(ideaType: node.attribute("type") ?? "")

        var mainClass: String?
        var jarPath: String?
        var moduleName: String?
        var vmOptions: String?
        var programArguments: String?
        var workingDirectory: String?
        var jreReference: String?
        var jreExplicitlyDisabled = false
        var springProfiles: [String] = []
        var includeProvided = false
        var allowParallel = false
        var environmentVariables: [String: String] = [:]
        var environmentFiles: [String] = []
        var passParentEnvironment = true
        var compoundMembers: [CompoundMember] = []
        var beforeLaunchTasks: [BeforeLaunchTask] = []
        var rawOptions: [String: String] = [:]
        var warnings: [ConfigurationWarning] = []

        // Maven 的 MavenSettings 是嵌套结构；JUnit 的目标字段也是独立的
        // TEST_OBJECT 家族。二者在这里聚合，循环结束后统一转成选项模型。
        var mavenSettingsNode: XMLElementNode?
        var junitTargetKind: String?
        var junitPackageName = ""
        var junitMethodName = ""
        var junitUniqueId = ""
        var junitProgramArguments = ""
        var junitDirectory: String?
        var junitPatterns: [String] = []
        var junitTags: [String] = []

        for child in node.children {
            switch child.name {
            case "option":
                guard let optionName = child.attribute("name") else { continue }
                let value = child.attribute("value") ?? ""
                if mainClassAliases.contains(optionName) {
                    if mainClass == nil, !value.isEmpty { mainClass = value }
                } else if jarPathAliases.contains(optionName) {
                    if jarPath == nil, !value.isEmpty { jarPath = value }
                } else if vmAliases.contains(optionName) {
                    if vmOptions == nil, !value.isEmpty { vmOptions = value }
                } else if programArgumentsAliases.contains(optionName) {
                    if programArguments == nil, !value.isEmpty { programArguments = value }
                } else if workingDirectoryAliases.contains(optionName) {
                    if workingDirectory == nil, !value.isEmpty { workingDirectory = value }
                } else if jreAliases.contains(optionName) {
                    if jreReference == nil, !value.isEmpty { jreReference = value }
                } else if jreEnabledAliases.contains(optionName) {
                    if value == "false" { jreExplicitlyDisabled = true }
                } else if springProfilesAliases.contains(optionName) {
                    if springProfiles.isEmpty { springProfiles = splitProfiles(value) }
                } else if includeProvidedAliases.contains(optionName) {
                    includeProvided = includeProvided || value == "true"
                } else if allowParallelAliases.contains(optionName) {
                    allowParallel = allowParallel || value == "true"
                } else if envFileAliases.contains(optionName) {
                    if environmentFiles.isEmpty, !value.isEmpty {
                        environmentFiles = value
                            .split(whereSeparator: { $0 == ":" || $0 == ";" })
                            .map(String.init)
                    }
                } else if passParentEnvAliases.contains(optionName) {
                    passParentEnvironment = value != "false"
                } else if type == .junit, optionName == "TEST_OBJECT" {
                    junitTargetKind = value
                } else if type == .junit, optionName == "METHOD_NAME" {
                    junitMethodName = value
                } else if type == .junit, optionName == "PACKAGE_NAME" {
                    junitPackageName = value
                } else if type == .junit, optionName == "UNIQUE_ID" {
                    junitUniqueId = value
                } else if type == .junit, optionName == "PARAMETERS" {
                    junitProgramArguments = value
                } else if type == .junit, optionName == "DIR" {
                    if junitDirectory == nil, !value.isEmpty { junitDirectory = value }
                } else if type == .junit, optionName == "TEST_SEARCH_SCOPE" {
                    // IDEA 界面里的搜索范围，不改变要执行的测试集合。
                } else {
                    rawOptions[optionName] = value
                }
            case "module":
                if moduleName == nil, let moduleNameValue = child.attribute("name"), !moduleNameValue.isEmpty {
                    moduleName = moduleNameValue
                }
            case "envs":
                for envNode in child.children where envNode.name == "env" {
                    if let key = envNode.attribute("name"), !key.isEmpty {
                        environmentVariables[key] = envNode.attribute("value") ?? ""
                    }
                }
            case "method":
                parseBeforeLaunchTasks(from: child, into: &beforeLaunchTasks, warnings: &warnings)
            case "toRun":
                if let memberName = child.attribute("name"), !memberName.isEmpty {
                    compoundMembers.append(CompoundMember(name: memberName, type: child.attribute("type") ?? ""))
                }
            case "MavenSettings" where type == .maven:
                mavenSettingsNode = child
            case "patterns" where type == .junit:
                for pattern in child.children where pattern.name == "pattern" {
                    guard let testClass = pattern.attribute("testClass"), !testClass.isEmpty else { continue }
                    let methodName = pattern.attribute("methodName") ?? ""
                    let normalized = methodName.isEmpty ? testClass : "\(testClass)#\(methodName)"
                    if !junitPatterns.contains(normalized) { junitPatterns.append(normalized) }
                }
            case "dir" where type == .junit:
                if junitDirectory == nil {
                    let value = child.attribute("value") ?? child.attribute("path") ?? ""
                    if !value.isEmpty { junitDirectory = value }
                }
            case "tag" where type == .junit:
                if let value = child.attribute("value"), !value.isEmpty, !junitTags.contains(value) {
                    junitTags.append(value)
                }
            case "tags" where type == .junit:
                for tag in child.children where tag.name == "tag" {
                    if let value = tag.attribute("value"), !value.isEmpty, !junitTags.contains(value) {
                        junitTags.append(value)
                    }
                }
            default:
                break
            }
        }

        var mavenOptions: MavenRunOptions?
        if type == .maven {
            let parsed = parseMavenOptions(from: mavenSettingsNode)
            mavenOptions = parsed.options
            if workingDirectory == nil, let parsedWorkingDirectory = parsed.workingDirectory, !parsedWorkingDirectory.isEmpty {
                workingDirectory = parsedWorkingDirectory
            }
            if let parsedPassParent = parsed.passParentEnvironment {
                passParentEnvironment = parsedPassParent
            }
            // 顶层 <envs> 与 Maven Runner 的 environmentProperties 都是 Maven 进程环境；
            // 顶层显式值优先。
            for (key, value) in parsed.options.environmentVariables where environmentVariables[key] == nil {
                environmentVariables[key] = value
            }
        }

        var junitOptions: JUnitRunOptions?
        if type == .junit {
            junitOptions = JUnitRunOptions(
                target: deriveJUnitTarget(
                    kind: junitTargetKind,
                    className: mainClass,
                    methodName: junitMethodName,
                    packageName: junitPackageName,
                    directory: junitDirectory,
                    patterns: junitPatterns,
                    tags: junitTags,
                    uniqueId: junitUniqueId
                ),
                programArguments: junitProgramArguments
            )
            if moduleName == nil {
                warnings.append(.missingModule)
            }
        }

        if jreExplicitlyDisabled {
            jreReference = nil
        }

        if type == .application || type == .springBoot {
            if mainClass == nil { warnings.append(.missingMainClass) }
            if moduleName == nil { warnings.append(.missingModule) }
        }
        if type == .jar, jarPath == nil {
            warnings.append(.missingJarPath)
        }
        if type == .compound && compoundMembers.isEmpty {
            warnings.append(.custom(title: "Compound 配置为空", detail: "“\(name)” 未引用任何子配置。"))
        }

        return RunConfiguration(
            name: name,
            type: type,
            mainClass: mainClass,
            jarPath: jarPath,
            moduleName: moduleName,
            jreReference: jreReference,
            vmOptions: vmOptions,
            programArguments: programArguments,
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables,
            environmentFiles: environmentFiles,
            passParentEnvironment: passParentEnvironment,
            springProfiles: springProfiles,
            includeProvidedDependencies: includeProvided,
            allowParallelRun: allowParallel,
            compoundMembers: compoundMembers,
            beforeLaunchTasks: beforeLaunchTasks,
            mavenOptions: mavenOptions,
            junitOptions: junitOptions,
            source: source,
            rawOptions: rawOptions,
            warnings: warnings
        )
    }

    // MARK: - Maven

    private struct ParsedMavenSettings {
        var options = MavenRunOptions()
        var passParentEnvironment: Bool?
        var workingDirectory: String?
    }

    private static func parseMavenOptions(from settingsNode: XMLElementNode?) -> ParsedMavenSettings {
        var parsed = ParsedMavenSettings()
        guard let settingsNode else { return parsed }
        var unsupported: [String] = []

        if let parameters = settingsNode.firstDescendant(named: "MavenRunnerParameters") {
            parsed.options.goals = optionValues(in: parameters, name: "goals")
            parsed.options.commandLineOptions = optionValue(in: parameters, name: "cmdOptions") ?? ""
            parsed.options.pomFileName = optionValue(in: parameters, name: "pomFileName") ?? ""
            parsed.options.profiles = optionValues(in: parameters, name: "profiles")
            for (profile, active) in optionMap(in: parameters, name: "profilesMap") where active == "true" {
                if !parsed.options.profiles.contains(profile) { parsed.options.profiles.append(profile) }
            }
            parsed.options.selectedProjects = optionValues(in: parameters, name: "projectsCmdOptionValues")
            if let workingDirectory = nonEmpty(optionValue(in: parameters, name: "workingDirPath")) {
                parsed.workingDirectory = workingDirectory
            }
            // IDEA 用它定位多模块 -pl 的根；没有等价命令行参数时不能假装支持。
            if nonEmpty(optionValue(in: parameters, name: "multimoduleDir")) != nil {
                unsupported.append("multimoduleDir")
            }
            unsupported += unknownOptions(in: parameters, handled: [
                "cmdOptions", "goals", "multimoduleDir", "pomFileName", "profiles",
                "profilesMap", "projectsCmdOptionValues", "resolveToWorkspace", "workingDirPath",
            ])
        }

        var generalArguments: [String] = []
        if let general = settingsNode.firstDescendant(named: "MavenGeneralSettings") {
            if boolOption(in: general, name: "workOffline") {
                generalArguments.append("-o")
            }
            if boolOption(in: general, name: "alwaysUpdateSnapshots") {
                parsed.options.updateSnapshots = true
                generalArguments.append("-U")
            }
            if let threads = nonEmpty(optionValue(in: general, name: "threads")) {
                generalArguments += ["-T", threads]
            }
            if let level = nonEmpty(optionValue(in: general, name: "outputLevel")) {
                switch level {
                case "INFO": break
                case "DEBUG": generalArguments.append("-X")
                case "QUIET": generalArguments.append("-q")
                default: unsupported.append("outputLevel=\(level)")
                }
            }
            if let checksum = nonEmpty(optionValue(in: general, name: "checksumPolicy")) {
                switch checksum {
                case "FAIL": generalArguments.append("-C")
                case "WARN": generalArguments.append("-c")
                case "IGNORE": break
                default: unsupported.append("checksumPolicy=\(checksum)")
                }
            }
            if let behavior = nonEmpty(optionValue(in: general, name: "failureBehavior")) {
                switch behavior {
                case "ERROR": break
                case "FAIL_FAST": generalArguments.append("-ff")
                case "FAIL_AT_END": generalArguments.append("-fae")
                case "FAIL_NEVER": generalArguments.append("-fn")
                default: unsupported.append("failureBehavior=\(behavior)")
                }
            }
            if boolOption(in: general, name: "printErrorStackTraces") {
                generalArguments.append("-e")
            }
            if boolOption(in: general, name: "usePluginRegistry") {
                unsupported.append("usePluginRegistry")
            }
            if let mavenHome = nonEmpty(optionValue(in: general, name: "mavenHome")),
               mavenHome != "Use Maven wrapper",
               !mavenHome.hasPrefix("Bundled") {
                unsupported.append("mavenHome")
            }
            if nonEmpty(optionValue(in: general, name: "userSettingsFile")) != nil {
                unsupported.append("userSettingsFile")
            }
            if nonEmpty(optionValue(in: general, name: "localRepository")) != nil {
                unsupported.append("localRepository")
            }
            unsupported += unknownOptions(in: general, handled: [
                "alwaysUpdateSnapshots", "checksumPolicy", "failureBehavior", "localRepository",
                "mavenHome", "outputLevel", "printErrorStackTraces", "threads",
                "usePluginRegistry", "userSettingsFile", "workOffline",
            ])
        }
        parsed.options.generalArguments = generalArguments

        if let runner = settingsNode.firstDescendant(named: "MavenRunnerSettings") {
            parsed.options.skipTests = boolOption(in: runner, name: "skipTests")
            parsed.options.vmOptions = optionValue(in: runner, name: "vmOptions") ?? ""
            parsed.options.jreName = nonEmpty(optionValue(in: runner, name: "jreName")) ?? "#USE_PROJECT_JDK"
            if let passParent = optionValue(in: runner, name: "passParentEnv") {
                parsed.passParentEnvironment = passParent != "false"
            }
            parsed.options.environmentVariables = optionMap(in: runner, name: "environmentProperties")
            parsed.options.properties = optionMap(in: runner, name: "mavenProperties")
            unsupported += unknownOptions(in: runner, handled: [
                "delegateBuildToMaven", "environmentProperties", "jreName", "mavenProperties",
                "passParentEnv", "runMavenInBackground", "skipTests", "vmOptions",
            ])
        }

        parsed.options.unsupportedOptions = deduplicated(unsupported)
        return parsed
    }

    private static func optionValue(in node: XMLElementNode, name: String) -> String? {
        node.children.first { $0.name == "option" && $0.attribute("name") == name }?.attribute("value")
    }

    private static func optionValues(in node: XMLElementNode, name: String) -> [String] {
        guard let container = node.children.first(where: { $0.name == "option" && $0.attribute("name") == name }),
              let list = container.firstChild("list") ?? container.firstChild("set") else {
            return []
        }
        return list.children
            .filter { $0.name == "option" }
            .compactMap { $0.attribute("value") }
            .filter { !$0.isEmpty }
    }

    private static func optionMap(in node: XMLElementNode, name: String) -> [String: String] {
        guard let container = node.children.first(where: { $0.name == "option" && $0.attribute("name") == name }),
              let map = container.firstChild("map") else {
            return [:]
        }
        var result: [String: String] = [:]
        for entry in map.children where entry.name == "entry" {
            guard let key = entry.attribute("key"), !key.isEmpty else { continue }
            result[key] = entry.attribute("value") ?? ""
        }
        return result
    }

    private static func boolOption(in node: XMLElementNode, name: String) -> Bool {
        optionValue(in: node, name: name) == "true"
    }

    /// IDEA 的默认值与 "null" 占位不算“不支持字段”，其余未知 option 必须显式带出。
    private static func unknownOptions(in node: XMLElementNode, handled: Set<String>) -> [String] {
        node.children.compactMap { child -> String? in
            guard child.name == "option",
                  let name = child.attribute("name"),
                  !handled.contains(name) else { return nil }
            let value = child.attribute("value") ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "null", trimmed != "false" else { return nil }
            return name
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    // MARK: - JUnit

    private static func deriveJUnitTarget(
        kind: String?,
        className: String?,
        methodName: String,
        packageName: String,
        directory: String?,
        patterns: [String],
        tags: [String],
        uniqueId: String
    ) -> JUnitRunOptions.Target {
        let className = nonEmpty(className)
        switch kind {
        case "class":
            guard let className else { return .unsupported("缺少测试类（MAIN_CLASS_NAME）") }
            return .className(className)
        case "method":
            guard let className else { return .unsupported("缺少测试类（MAIN_CLASS_NAME）") }
            let method = methodName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !method.isEmpty else { return .unsupported("缺少测试方法（METHOD_NAME）") }
            return .method(className: className, methodName: method)
        case "package":
            let package = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
            // IDEA 2020+ 用空 PACKAGE_NAME + package 表示整个模块。
            return package.isEmpty ? .all : .package(package)
        case "directory":
            guard let directory = nonEmpty(directory) else { return .unsupported("缺少测试目录") }
            return .directory(directory)
        case "pattern":
            return patterns.isEmpty ? .unsupported("测试模式为空") : .patterns(patterns)
        case "tags":
            return tags.isEmpty ? .unsupported("测试标签为空") : .tags(tags)
        case "uniqueId":
            return .uniqueId(uniqueId.isEmpty ? "（空）" : uniqueId)
        case nil:
            // IDEA 的默认 TEST_OBJECT 是 class。
            if let className { return .className(className) }
            return .unsupported("缺少测试目标")
        case .some(let raw):
            return .unsupported("TEST_OBJECT=\(raw)")
        }
    }

    /// §30: Before Launch 识别 Build / Build Project / Run Another Configuration /
    /// Maven / Gradle 任务，其余任务产生 warning，不偷偷忽略。
    private static func parseBeforeLaunchTasks(
        from methodNode: XMLElementNode,
        into tasks: inout [BeforeLaunchTask],
        warnings: inout [ConfigurationWarning]
    ) {
        for option in methodNode.children where option.name == "option" {
            guard let taskName = option.attribute("name") else { continue }
            let enabled = option.attribute("enabled") != "false"
            switch taskName {
            case "Make", "make":
                tasks.append(BeforeLaunchTask(kind: .build, isEnabled: enabled))
            case "BuildProject", "build.project", "MakeProject":
                tasks.append(BeforeLaunchTask(kind: .buildProject, isEnabled: enabled))
            case "Maven.BeforeRunTask":
                let goal = option.attribute("goal")
                    ?? option.attribute("runnerParams")
                    ?? option.firstChild("param")?.attribute("value")
                    ?? ""
                // §P0-9: `file` 指定对哪个 pom 执行（子模块任务时是子模块 pom），
                // 丢弃它等于把任务静默改写到项目根，语义完全变了。
                let pomFile = option.attribute("file")
                tasks.append(BeforeLaunchTask(kind: .mavenGoal(goal: goal, pomFile: pomFile), isEnabled: enabled))
            case "Gradle.BeforeRunTask":
                let task = option.attribute("tasks")
                    ?? option.attribute("taskName")
                    ?? option.attribute("task")
                    ?? ""
                tasks.append(BeforeLaunchTask(kind: .gradleTask(task: task), isEnabled: enabled))
            case "RunConfigurationTask":
                // IDEA 的 .run.xml 用属性保存引用；workspace.xml 的旧形式是子元素 configuration。
                let referenced = option.firstChild("configuration")
                let name = option.attribute("run_configuration_name") ?? referenced?.attribute("name")
                let type = option.attribute("run_configuration_type") ?? referenced?.attribute("type")
                if let referencedName = name, !referencedName.isEmpty {
                    tasks.append(BeforeLaunchTask(
                        kind: .runConfiguration(name: referencedName, type: type),
                        isEnabled: enabled
                    ))
                } else if enabled {
                    warnings.append(.unsupportedBeforeLaunch(description: "RunConfigurationTask（缺少配置引用）"))
                }
            case "ActivateToolWindow", "ToolWindow.BeforeRunTask":
                break
            default:
                // §3.2: 未知任务必须留在任务列表里——GUI 能看到警告，
                // Core 在执行阶段 fail closed。只留警告等于偷偷忽略。
                tasks.append(BeforeLaunchTask(kind: .unknown(raw: taskName), isEnabled: enabled))
                if enabled {
                    warnings.append(.unsupportedBeforeLaunch(description: taskName))
                }
            }
        }
    }

    static func splitProfiles(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
