import Foundation

// §8: 所有 IDEA XML 最终转为统一模型，UI 只面对该模型。

public enum Readiness: String, Codable, Sendable {
    case ready
    case warning
    case planned
    case unsupported
}

public enum RunConfigurationType: Equatable, Hashable, Codable, Sendable {
    case application
    case springBoot
    case compound
    case jar
    case maven
    case gradle
    case junit
    case unknown(String)

    /// §10: 宽松解析——按 IDEA type id 映射，未知类型不丢弃而是保留原始值。
    public static func from(ideaType: String) -> RunConfigurationType {
        switch ideaType {
        case "Application":
            return .application
        case "SpringBootApplicationConfigurationType":
            return .springBoot
        case "CompoundRunConfigurationType":
            return .compound
        case "JarApplicationType", "JarApplication":
            return .jar
        case "MavenRunConfigurationType":
            return .maven
        case "GradleRunConfiguration":
            return .gradle
        case "JUnit":
            return .junit
        default:
            return .unknown(ideaType)
        }
    }

    public var ideaTypeRaw: String {
        switch self {
        case .application: return "Application"
        case .springBoot: return "SpringBootApplicationConfigurationType"
        case .compound: return "CompoundRunConfigurationType"
        case .jar: return "JarApplicationType"
        case .maven: return "MavenRunConfigurationType"
        case .gradle: return "GradleRunConfiguration"
        case .junit: return "JUnit"
        case .unknown(let raw): return raw
        }
    }

    public var displayName: String {
        switch self {
        case .application: return "Application"
        case .springBoot: return "Spring Boot"
        case .compound: return "Compound"
        case .jar: return "JAR Application"
        case .maven: return "Maven"
        case .gradle: return "Gradle"
        case .junit: return "JUnit"
        case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }

    /// 类型本身只负责识别、显示与排序；能否启动由
    /// `ConfigurationCapabilityResolver` 结合项目实际计算（§P0-5）。
    public var sortRank: Int {
        switch self {
        case .springBoot: return 0
        case .application: return 1
        case .compound: return 2
        case .maven: return 3
        case .gradle: return 4
        case .jar: return 5
        case .junit: return 6
        case .unknown: return 7
        }
    }
}

public struct CompoundMember: Equatable, Hashable, Codable, Sendable {
    public var name: String
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }

    /// 与 `RunConfiguration.uniqueKey` 同构：IDEA 的 toRun 保存的就是 type id。
    public var uniqueKey: String { "\(type)::\(name)" }
}

public struct BeforeLaunchTask: Equatable, Hashable, Codable, Sendable {
    public enum Kind: Equatable, Hashable, Codable, Sendable {
        case build
        case buildProject
        case runConfiguration(name: String, type: String?)
        /// §P0-9: IDEA 的 Maven.BeforeRunTask 除 goal 外还保存 `file`（对哪个 pom 执行，
        /// 常见于子模块）。pomFile 丢了任务就会跑到项目根上去，语义完全变了。
        case mavenGoal(goal: String, pomFile: String?)
        case gradleTask(task: String)
        case unknown(raw: String)
    }

    public var kind: Kind
    public var isEnabled: Bool

    public init(kind: Kind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }

    public var displayName: String {
        switch kind {
        case .build: return "Build"
        case .buildProject: return "Build Project"
        case .runConfiguration(let name, _): return "Run \(name)"
        case .mavenGoal(let goal, _): return "Maven: \(goal)"
        case .gradleTask(let task): return "Gradle: \(task)"
        case .unknown(let raw): return raw
        }
    }
}

public enum ConfigurationWarning: Equatable, Hashable, Codable, Sendable {
    case unresolvedMacro(token: String, rawValue: String)
    case ideaContextMacro(name: String, rawValue: String)
    case unsupportedBeforeLaunch(description: String)
    case missingMainClass
    case missingModule
    case missingJarPath
    case moduleNotFound(name: String)
    case custom(title: String, detail: String)

    public var title: String {
        switch self {
        case .unresolvedMacro:
            return "存在无法解析的变量"
        case .ideaContextMacro:
            return "存在 IDEA 上下文变量"
        case .unsupportedBeforeLaunch:
            return "包含尚未支持的 Before Launch 操作"
        case .missingMainClass:
            return "缺少 Main Class"
        case .missingModule:
            return "缺少 Module"
        case .missingJarPath:
            return "缺少 JAR 路径"
        case .moduleNotFound:
            return "找不到对应 Module"
        case .custom(let title, _):
            return title
        }
    }

    public var detail: String {
        switch self {
        case .unresolvedMacro(let token, let raw):
            return "无法解析 \(token)（原始值：\(raw)），启动前需要手动覆盖。"
        case .ideaContextMacro(let name, let raw):
            return "\(raw) 依赖 IDEA 当前上下文（$\(name)$），IdeaLightRun 不会伪造该值。"
        case .unsupportedBeforeLaunch(let description):
            return "Before Launch 任务 “\(description)” 尚未支持，默认不会执行。"
        case .missingMainClass:
            return "配置中没有 Main Class 字段。"
        case .missingModule:
            return "配置中没有 Module 字段。"
        case .missingJarPath:
            return "配置中没有 JAR Path 字段。"
        case .moduleNotFound(let name):
            return "无法将 module “\(name)” 映射到项目目录。"
        case .custom(_, let detail):
            return detail
        }
    }
}

/// IDEA Maven 运行配置（MavenRunConfigurationType）的执行参数。
///
/// 这里只保留会改变 Maven 进程语义的字段。IDEA 的 General Settings 里
/// 无法等价映射的选项（自定义 mavenHome、userSettingsFile 等）进入
/// `unsupportedOptions`，由能力判定显式拒绝——不能悄悄按默认 Maven 跑。
public struct MavenRunOptions: Equatable, Codable, Sendable {
    /// IDEA 的 goals 列表，原文保存（如 `clean`、`spring-boot:run`）。
    public var goals: [String]
    /// IDEA 的 "Command line"（cmdOptions），执行前再分词。
    public var commandLineOptions: String
    /// IDEA 的 pomFileName；空表示工作目录下的 pom.xml。
    public var pomFileName: String
    public var profiles: [String]
    /// Maven Runner 的 properties，映射为 `-Dkey=value`。
    public var properties: [String: String]
    /// Maven Runner 的 environmentProperties，只作用于 Maven 进程。
    public var environmentVariables: [String: String]
    /// Maven Runner 的 vmOptions，映射为 `MAVEN_OPTS`。
    public var vmOptions: String
    /// `#USE_PROJECT_JDK`（IDEA 默认）或 `#JAVA_HOME`；其余值暂不支持。
    public var jreName: String
    public var skipTests: Bool
    /// General Settings 中可等价映射的选项（`-o` / `-T 1C` / `-X` 等）。
    public var generalArguments: [String]
    /// `alwaysUpdateSnapshots` 的原始值。实际参数已由 General Settings 映射进
    /// `generalArguments`（`-U`）；直接运行不追加 `-nsu`，保留该字段供展示与诊断。
    public var updateSnapshots: Bool
    /// `projectsCmdOptionValues`：Maven `-pl` 的工程列表。
    public var selectedProjects: [String]
    /// 无法等价映射的 IDEA 选项名（原始字段名），非空时不允许 READY。
    public var unsupportedOptions: [String]

    public init(
        goals: [String] = [],
        commandLineOptions: String = "",
        pomFileName: String = "",
        profiles: [String] = [],
        properties: [String: String] = [:],
        environmentVariables: [String: String] = [:],
        vmOptions: String = "",
        jreName: String = "#USE_PROJECT_JDK",
        skipTests: Bool = false,
        generalArguments: [String] = [],
        updateSnapshots: Bool = false,
        selectedProjects: [String] = [],
        unsupportedOptions: [String] = []
    ) {
        self.goals = goals
        self.commandLineOptions = commandLineOptions
        self.pomFileName = pomFileName
        self.profiles = profiles
        self.properties = properties
        self.environmentVariables = environmentVariables
        self.vmOptions = vmOptions
        self.jreName = jreName
        self.skipTests = skipTests
        self.generalArguments = generalArguments
        self.updateSnapshots = updateSnapshots
        self.selectedProjects = selectedProjects
        self.unsupportedOptions = unsupportedOptions
    }
}

/// IDEA JUnit 运行配置（type="JUnit"）的测试目标。
/// IDEA 的 `TEST_OBJECT` 决定解释方式；空 PACKAGE_NAME + package 表示整个模块。
public struct JUnitRunOptions: Equatable, Codable, Sendable {
    public enum Target: Equatable, Hashable, Codable, Sendable {
        case all
        case className(String)
        case method(className: String, methodName: String)
        case package(String)
        case directory(String)
        /// 规范化成 `Class` 或 `Class#method`，构建系统再转成各自的过滤语法。
        case patterns([String])
        case tags([String])
        case uniqueId(String)
        case unsupported(String)

        public var displayText: String {
            switch self {
            case .all:
                return "整个模块"
            case .className(let name):
                return name
            case .method(let className, let methodName):
                return "\(className)#\(methodName)"
            case .package(let name):
                return "包 \(name)"
            case .directory(let path):
                return "目录 \(path)"
            case .patterns(let patterns):
                return patterns.joined(separator: ", ")
            case .tags(let tags):
                return "标签 \(tags.joined(separator: ", "))"
            case .uniqueId(let id):
                return "Unique ID \(id)"
            case .unsupported(let raw):
                return raw
            }
        }
    }

    public var target: Target
    /// IDEA 的 `PARAMETERS` 会传给测试运行器；Surefire / Gradle 的测试 fork
    /// 没有等价入口，非空时能力判定会拒绝，而不是丢弃。
    public var programArguments: String

    public init(target: Target, programArguments: String = "") {
        self.target = target
        self.programArguments = programArguments
    }
}

/// §7: 配置来源优先级，rawValue 越小优先级越高。
public struct ConfigurationSource: Equatable, Codable, Sendable {
    public enum Kind: Int, Equatable, Codable, Sendable, Comparable {
        case dotRun = 0
        case projectRunXML = 1
        case ideaRunConfigurations = 2
        case workspaceXML = 3

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        public var displayName: String {
            switch self {
            case .dotRun: return ".run/*.run.xml"
            case .projectRunXML: return "project *.run.xml"
            case .ideaRunConfigurations: return ".idea/runConfigurations"
            case .workspaceXML: return ".idea/workspace.xml"
            }
        }
    }

    public var kind: Kind
    public var file: URL
    public var modifiedAt: Date?

    public init(kind: Kind, file: URL, modifiedAt: Date?) {
        self.kind = kind
        self.file = file
        self.modifiedAt = modifiedAt
    }
}

public struct RunConfiguration: Identifiable, Equatable, Codable, Sendable {
    /// §7: 唯一键 = type + name。
    public var uniqueKey: String { "\(type.ideaTypeRaw)::\(name)" }
    public var id: String { uniqueKey }

    public var name: String
    public var type: RunConfigurationType
    public var mainClass: String?
    /// JAR Application 的 `JAR_PATH`（IDEA 的 JarApplicationConfigurationBean）。
    /// Application / Spring Boot 为 nil。
    public var jarPath: String?
    public var moduleName: String?
    public var jreReference: String?
    public var vmOptions: String?
    public var programArguments: String?
    /// 未展开的原始值（可能含 $PROJECT_DIR$ 等宏）。
    public var workingDirectory: String?
    public var environmentVariables: [String: String]
    public var environmentFiles: [String]
    /// §4.1/§4.2: IDEA 的 "Include system environment variables"（PASS_PARENT_ENVS）。
    /// false 时不继承父进程环境，只保留最小启动环境与配置自身的变量。
    public var passParentEnvironment: Bool
    public var springProfiles: [String]
    public var includeProvidedDependencies: Bool
    public var allowParallelRun: Bool
    public var compoundMembers: [CompoundMember]
    public var beforeLaunchTasks: [BeforeLaunchTask]
    /// Maven 直接运行参数；仅 `.maven` 配置有值。
    public var mavenOptions: MavenRunOptions?
    /// JUnit 测试目标；仅 `.junit` 配置有值。
    public var junitOptions: JUnitRunOptions?
    public var source: ConfigurationSource
    /// §10: 未知字段进入 rawOptions，保证 IDEA 新字段不至于让解析整体失败。
    public var rawOptions: [String: String]
    public var warnings: [ConfigurationWarning]

    public init(
        name: String,
        type: RunConfigurationType,
        mainClass: String? = nil,
        jarPath: String? = nil,
        moduleName: String? = nil,
        jreReference: String? = nil,
        vmOptions: String? = nil,
        programArguments: String? = nil,
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = [:],
        environmentFiles: [String] = [],
        passParentEnvironment: Bool = true,
        springProfiles: [String] = [],
        includeProvidedDependencies: Bool = false,
        allowParallelRun: Bool = false,
        compoundMembers: [CompoundMember] = [],
        beforeLaunchTasks: [BeforeLaunchTask] = [],
        mavenOptions: MavenRunOptions? = nil,
        junitOptions: JUnitRunOptions? = nil,
        source: ConfigurationSource,
        rawOptions: [String: String] = [:],
        warnings: [ConfigurationWarning] = []
    ) {
        self.name = name
        self.type = type
        self.mainClass = mainClass
        self.jarPath = jarPath
        self.moduleName = moduleName
        self.jreReference = jreReference
        self.vmOptions = vmOptions
        self.programArguments = programArguments
        self.workingDirectory = workingDirectory
        self.environmentVariables = environmentVariables
        self.environmentFiles = environmentFiles
        self.passParentEnvironment = passParentEnvironment
        self.springProfiles = springProfiles
        self.includeProvidedDependencies = includeProvidedDependencies
        self.allowParallelRun = allowParallelRun
        self.compoundMembers = compoundMembers
        self.beforeLaunchTasks = beforeLaunchTasks
        self.mavenOptions = mavenOptions
        self.junitOptions = junitOptions
        self.source = source
        self.rawOptions = rawOptions
        self.warnings = warnings
    }
}

extension RunConfiguration {
    /// 没有项目上下文时的类型/字段级结论。界面与门禁需要项目感知的结果时，
    /// 必须调用 `ConfigurationCapabilityResolver.resolve(_:scan:)`。
    public var readiness: Readiness {
        ConfigurationCapabilityResolver.resolve(self).readiness
    }
}
