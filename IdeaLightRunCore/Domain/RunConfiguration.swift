import Foundation

// §8: 所有 IDEA XML 最终转为统一模型，UI 只面对该模型。

public enum SupportLevel: String, Codable, Sendable {
    case supported
    case planned
    case unsupported
}

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

    /// §79: 只区分 Ready / Warning / Unsupported，不做兼容性分数。
    public var supportLevel: SupportLevel {
        switch self {
        case .application, .springBoot:
            return .supported
        case .compound, .jar, .maven, .gradle:
            return .planned
        case .junit, .unknown:
            return .unsupported
        }
    }

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
}

public struct BeforeLaunchTask: Equatable, Hashable, Codable, Sendable {
    public enum Kind: Equatable, Hashable, Codable, Sendable {
        case build
        case buildProject
        case runConfiguration(name: String, type: String?)
        case mavenGoal(goal: String)
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
        case .mavenGoal(let goal): return "Maven: \(goal)"
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
        case .moduleNotFound(let name):
            return "无法将 module “\(name)” 映射到项目目录。"
        case .custom(_, let detail):
            return detail
        }
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
    public var moduleName: String?
    public var jreReference: String?
    public var vmOptions: String?
    public var programArguments: String?
    /// 未展开的原始值（可能含 $PROJECT_DIR$ 等宏）。
    public var workingDirectory: String?
    public var environmentVariables: [String: String]
    public var environmentFiles: [String]
    public var springProfiles: [String]
    public var includeProvidedDependencies: Bool
    public var allowParallelRun: Bool
    public var compoundMembers: [CompoundMember]
    public var beforeLaunchTasks: [BeforeLaunchTask]
    public var source: ConfigurationSource
    /// §10: 未知字段进入 rawOptions，保证 IDEA 新字段不至于让解析整体失败。
    public var rawOptions: [String: String]
    public var warnings: [ConfigurationWarning]

    public init(
        name: String,
        type: RunConfigurationType,
        mainClass: String? = nil,
        moduleName: String? = nil,
        jreReference: String? = nil,
        vmOptions: String? = nil,
        programArguments: String? = nil,
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = [:],
        environmentFiles: [String] = [],
        springProfiles: [String] = [],
        includeProvidedDependencies: Bool = false,
        allowParallelRun: Bool = false,
        compoundMembers: [CompoundMember] = [],
        beforeLaunchTasks: [BeforeLaunchTask] = [],
        source: ConfigurationSource,
        rawOptions: [String: String] = [:],
        warnings: [ConfigurationWarning] = []
    ) {
        self.name = name
        self.type = type
        self.mainClass = mainClass
        self.moduleName = moduleName
        self.jreReference = jreReference
        self.vmOptions = vmOptions
        self.programArguments = programArguments
        self.workingDirectory = workingDirectory
        self.environmentVariables = environmentVariables
        self.environmentFiles = environmentFiles
        self.springProfiles = springProfiles
        self.includeProvidedDependencies = includeProvidedDependencies
        self.allowParallelRun = allowParallelRun
        self.compoundMembers = compoundMembers
        self.beforeLaunchTasks = beforeLaunchTasks
        self.source = source
        self.rawOptions = rawOptions
        self.warnings = warnings
    }
}

extension RunConfiguration {
    public var readiness: Readiness {
        switch type.supportLevel {
        case .unsupported:
            return .unsupported
        case .planned:
            return .planned
        case .supported:
            return warnings.isEmpty ? .ready : .warning
        }
    }
}
