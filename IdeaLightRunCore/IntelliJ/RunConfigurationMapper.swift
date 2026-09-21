import Foundation

/// §10: 已知字段 → 标准模型；未知字段 → rawOptions。字段名使用 alias 表，
/// 不假设某个字段永远只有一种写法。
public enum RunConfigurationMapper {
    static let mainClassAliases = ["MAIN_CLASS_NAME", "MAIN_CLASS", "SPRING_BOOT_MAIN_CLASS"]
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

        for child in node.children {
            switch child.name {
            case "option":
                guard let optionName = child.attribute("name") else { continue }
                let value = child.attribute("value") ?? ""
                if mainClassAliases.contains(optionName) {
                    if mainClass == nil, !value.isEmpty { mainClass = value }
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
            default:
                break
            }
        }

        if jreExplicitlyDisabled {
            jreReference = nil
        }

        if type == .application || type == .springBoot {
            if mainClass == nil { warnings.append(.missingMainClass) }
            if moduleName == nil { warnings.append(.missingModule) }
        }
        if type == .compound && compoundMembers.isEmpty {
            warnings.append(.custom(title: "Compound 配置为空", detail: "“\(name)” 未引用任何子配置。"))
        }

        return RunConfiguration(
            name: name,
            type: type,
            mainClass: mainClass,
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
            source: source,
            rawOptions: rawOptions,
            warnings: warnings
        )
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
                tasks.append(BeforeLaunchTask(kind: .mavenGoal(goal: goal), isEnabled: enabled))
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
