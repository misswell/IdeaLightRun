import Foundation

/// 一个能力维度的支持级别。`limited` / `restart` 都带原因，
/// 界面必须把原因原样显示出来，不能只给一个绿色对勾。
public enum HotReloadSupportLevel: Equatable, Sendable, Codable {
    case supported
    case limited(String)
    case restart(String)
    case delegated
    case unsupported

    public var displayText: String {
        switch self {
        case .supported: return "支持"
        case .limited(let reason): return "有限支持：\(reason)"
        case .restart(let reason): return "需重启：\(reason)"
        case .delegated: return "由外部后端决定"
        case .unsupported: return "不支持"
        }
    }

    public var isDirectlySupported: Bool {
        switch self {
        case .supported, .limited:
            return true
        case .restart, .delegated, .unsupported:
            return false
        }
    }
}

/// 热更新后端能力矩阵。任何人（README / UI / 日志）都只能引用这里的结果，
/// 不允许在别处宣称“支持字段/方法变更”。
public struct HotReloadCapability: Equatable, Sendable {
    public var provider: HotReloadProviderKind
    public var methodBody: HotReloadSupportLevel
    public var structuralChanges: HotReloadSupportLevel
    public var newClasses: HotReloadSupportLevel
    public var springBeanRefresh: HotReloadSupportLevel
    public var resources: HotReloadSupportLevel
    public var note: String

    public init(
        provider: HotReloadProviderKind,
        methodBody: HotReloadSupportLevel,
        structuralChanges: HotReloadSupportLevel,
        newClasses: HotReloadSupportLevel,
        springBeanRefresh: HotReloadSupportLevel,
        resources: HotReloadSupportLevel,
        note: String
    ) {
        self.provider = provider
        self.methodBody = methodBody
        self.structuralChanges = structuralChanges
        self.newClasses = newClasses
        self.springBeanRefresh = springBeanRefresh
        self.resources = resources
        self.note = note
    }

    public struct Row: Identifiable, Sendable, Equatable {
        public var name: String
        public var level: HotReloadSupportLevel

        public var id: String { name }
    }

    public var rows: [Row] {
        [
            Row(name: "方法体变更", level: methodBody),
            Row(name: "字段 / 方法 / 继承结构变更", level: structuralChanges),
            Row(name: "新增 / 删除类", level: newClasses),
            Row(name: "Spring Bean 定义刷新", level: springBeanRefresh),
            Row(name: "资源文件变更", level: resources)
        ]
    }
}

/// 一次热更新动作的最终状态。`disabled` 只由界面在未启用时合成，
/// Core 的会话本身从 `listening` 开始。
public enum HotReloadState: Equatable, Sendable {
    case disabled
    case listening
    case compiling
    case applying
    case succeeded
    /// 部分类替换成功，或只有资源变化、运行期未必已重新加载。
    case partial
    case compileFailed
    case failed
    /// 变更超出当前后端能力（结构变更、删除类等）。
    case unsupported
    /// 需要重启，按回退策略等待用户确认或提示。
    case requiresRestart
    /// 已按策略请求重启（实际重启由外层执行器完成）。
    case restarted
    /// 已编译并交给 DevTools / 外部 Agent，IdeaLightRun 不宣称替换结果。
    case delegated
    case agentUnavailable
    /// FSEventStream 创建或启动失败；此时保存源码不会被发现。
    case watcherUnavailable
    /// 检测到源码变化但自动编译已关闭，等待用户手动触发。
    case attention
    case stopped

    public var displayText: String {
        switch self {
        case .disabled: return "未启用"
        case .listening: return "监听中"
        case .compiling: return "编译中"
        case .applying: return "应用中"
        case .succeeded: return "热更新成功"
        case .partial: return "部分更新"
        case .compileFailed: return "编译失败"
        case .failed: return "热更新失败"
        case .unsupported: return "变更超出后端能力"
        case .requiresRestart: return "需要重启"
        case .restarted: return "已请求重启"
        case .delegated: return "已交给外部后端"
        case .agentUnavailable: return "Agent 不可用"
        case .watcherUnavailable: return "文件监听不可用"
        case .attention: return "待手动编译"
        case .stopped: return "已停止"
        }
    }

    public var isBusy: Bool {
        self == .compiling || self == .applying
    }

    /// 需要用户处理（重启 / 排查）的状态。
    public var needsAttention: Bool {
        switch self {
        case .compileFailed, .failed, .unsupported, .requiresRestart,
             .agentUnavailable, .watcherUnavailable, .attention, .partial:
            return true
        default:
            return false
        }
    }
}

public enum HotReloadClassChangeKind: String, Equatable, Sendable {
    case modified
    case added
    case removed

    public var displayText: String {
        switch self {
        case .modified: return "修改"
        case .added: return "新增"
        case .removed: return "删除"
        }
    }
}

public struct HotReloadClassChange: Equatable, Sendable {
    public var className: String
    public var filePath: String
    public var kind: HotReloadClassChangeKind
    /// 该 class 文件所属的输出目录。同名类可能来自多个模块的 target/classes，
    /// Agent 必须据此匹配实际 ClassLoader，不能按类名取第一个。
    public var outputRoot: String?

    public init(
        className: String,
        filePath: String,
        kind: HotReloadClassChangeKind,
        outputRoot: String? = nil
    ) {
        self.className = className
        self.filePath = filePath
        self.kind = kind
        self.outputRoot = outputRoot
    }
}

/// 单个类为什么没有替换成功。分类决定 UI 的措辞与回退策略：
/// `schemaChange` / `notModifiable` 是标准 JVM 的硬边界，只能增强后端或重启。
public enum HotReloadFailureKind: String, Equatable, Sendable {
    case schemaChange
    case notModifiable
    case notLoaded
    case classNotFound
    case bytecodeRejected
    case classRemoved
    case agentUnreachable
    /// 同名类在多个 ClassLoader / 输出目录中出现，无法唯一确认该改哪一个。
    case ambiguousClass
    /// 请求的输出目录与类实际加载来源不一致。
    case classOriginMismatch
    /// 同一请求里的其它类被 JVM 拒绝，整组原子提交未发生；
    /// 这个类本身可能只是被牵连，但确实没有应用。
    case atomicGroupAborted
    case unknown

    public var displayText: String {
        switch self {
        case .schemaChange: return "结构变更（JVM 拒绝 schema 变化）"
        case .notModifiable: return "类不可修改"
        case .notLoaded: return "类尚未加载"
        case .classNotFound: return "Agent 找不到该类"
        case .bytecodeRejected: return "字节码被 JVM 拒绝"
        case .classRemoved: return "类文件已删除"
        case .agentUnreachable: return "Agent 控制通道不可达"
        case .ambiguousClass: return "同名类无法唯一匹配"
        case .classOriginMismatch: return "类加载来源不匹配"
        case .atomicGroupAborted: return "整组未应用（组内类被拒绝）"
        case .unknown: return "未知原因"
        }
    }

    /// 标准 HotSwap 无法跨越的边界；只能换增强 Agent 或重启。
    public var requiresEnhancedAgentOrRestart: Bool {
        switch self {
        case .schemaChange, .notModifiable, .classRemoved, .atomicGroupAborted:
            return true
        default:
            return false
        }
    }

    public static func classify(_ message: String) -> HotReloadFailureKind {
        let lower = message.lowercased()
        if lower.contains("atomic group") {
            return .atomicGroupAborted
        }
        if lower.contains("schema") {
            return .schemaChange
        }
        if lower.contains("unmodifiable") || lower.contains("not modifiable") {
            return .notModifiable
        }
        if lower.contains("not loaded") || lower.contains("未加载") {
            return .notLoaded
        }
        if lower.contains("classnotfound") || lower.contains("class not found") {
            return .classNotFound
        }
        if lower.contains("ambiguous") || lower.contains("cannot uniquely match") {
            return .ambiguousClass
        }
        if lower.contains("origin mismatch") || lower.contains("loaded from") {
            return .classOriginMismatch
        }
        if lower.contains("verifyerror") || lower.contains("classformaterror")
            || lower.contains("illegalclassformat") || lower.contains("bytecode") {
            return .bytecodeRejected
        }
        if lower.contains("agent unreachable") || lower.contains("connection refused")
            || lower.contains("control channel") {
            return .agentUnreachable
        }
        return .unknown
    }
}

public struct HotReloadClassFailure: Equatable, Sendable {
    public var className: String
    public var message: String
    public var kind: HotReloadFailureKind

    public init(className: String, message: String, kind: HotReloadFailureKind) {
        self.className = className
        self.message = message
        self.kind = kind
    }
}

/// 一次变更处理的可核对结果。所有计数都来自真实 diff / Agent 响应，
/// 不用“看起来应该成功”来填。
public struct HotReloadSummary: Equatable, Sendable {
    public var startedAt: Date
    public var duration: TimeInterval
    public var sourceChanges: [String]
    public var resourceChanges: [String]
    public var compiledModules: [String]
    public var classChanges: [HotReloadClassChange]
    public var appliedClasses: [String]
    public var skippedClasses: [HotReloadClassFailure]
    public var failedClasses: [HotReloadClassFailure]
    public var notes: [String]
    public var didCompile: Bool
    public var didApply: Bool
    public var didRestart: Bool

    public init(
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        sourceChanges: [String] = [],
        resourceChanges: [String] = [],
        compiledModules: [String] = [],
        classChanges: [HotReloadClassChange] = [],
        appliedClasses: [String] = [],
        skippedClasses: [HotReloadClassFailure] = [],
        failedClasses: [HotReloadClassFailure] = [],
        notes: [String] = [],
        didCompile: Bool = false,
        didApply: Bool = false,
        didRestart: Bool = false
    ) {
        self.startedAt = startedAt
        self.duration = duration
        self.sourceChanges = sourceChanges
        self.resourceChanges = resourceChanges
        self.compiledModules = compiledModules
        self.classChanges = classChanges
        self.appliedClasses = appliedClasses
        self.skippedClasses = skippedClasses
        self.failedClasses = failedClasses
        self.notes = notes
        self.didCompile = didCompile
        self.didApply = didApply
        self.didRestart = didRestart
    }

    public var isEmpty: Bool {
        sourceChanges.isEmpty && resourceChanges.isEmpty && classChanges.isEmpty
    }

    public var addedClassCount: Int {
        classChanges.filter { $0.kind == .added }.count
    }

    public var removedClassCount: Int {
        classChanges.filter { $0.kind == .removed }.count
    }

    public var hasUnsupportedFailure: Bool {
        failedClasses.contains { $0.kind.requiresEnhancedAgentOrRestart }
    }

    /// 控制台摘要：只报数量与类名，不打印 JVM 参数 / 环境变量。
    public var consoleLine: String {
        var parts: [String] = []
        if didCompile {
            parts.append("已编译 \(compiledModules.isEmpty ? "变更模块" : compiledModules.joined(separator: "、"))")
        }
        if !sourceChanges.isEmpty {
            parts.append("源文件 \(sourceChanges.count) 个")
        }
        if !classChanges.isEmpty {
            parts.append("class \(classChanges.count) 个（新增 \(addedClassCount)，删除 \(removedClassCount)）")
        }
        if didApply {
            parts.append("已替换 \(appliedClasses.count) 个类")
        }
        if !skippedClasses.isEmpty {
            parts.append("跳过 \(skippedClasses.count) 个")
        }
        if !failedClasses.isEmpty {
            parts.append("失败 \(failedClasses.count) 个")
        }
        if !resourceChanges.isEmpty {
            parts.append("资源 \(resourceChanges.count) 个")
        }
        if didRestart {
            parts.append("已请求重启")
        }
        return parts.isEmpty ? "没有变更" : parts.joined(separator: "；")
    }
}

/// 推给 GUI / 日志的只读快照。会话内部状态不直接暴露，避免界面读到半更新的字段。
public struct HotReloadSnapshot: Equatable, Sendable {
    public var state: HotReloadState
    public var detail: String
    public var configuration: HotReloadConfiguration
    public var provider: HotReloadProviderKind?
    public var capability: HotReloadCapability?
    public var summary: HotReloadSummary?
    public var awaitingRestartConfirmation: Bool
    public var canManualTrigger: Bool
    public var isWatching: Bool
    /// 监听启动失败的原文；非空时界面必须显示原因，不能只留一个“监听中”。
    public var watcherIssue: String?
    public var canRetryWatcher: Bool
    public var lastUpdated: Date

    public init(
        state: HotReloadState,
        detail: String = "",
        configuration: HotReloadConfiguration,
        provider: HotReloadProviderKind? = nil,
        capability: HotReloadCapability? = nil,
        summary: HotReloadSummary? = nil,
        awaitingRestartConfirmation: Bool = false,
        canManualTrigger: Bool = false,
        isWatching: Bool = false,
        watcherIssue: String? = nil,
        canRetryWatcher: Bool = false,
        lastUpdated: Date = Date()
    ) {
        self.state = state
        self.detail = detail
        self.configuration = configuration
        self.provider = provider
        self.capability = capability
        self.summary = summary
        self.awaitingRestartConfirmation = awaitingRestartConfirmation
        self.canManualTrigger = canManualTrigger
        self.isWatching = isWatching
        self.watcherIssue = watcherIssue
        self.canRetryWatcher = canRetryWatcher
        self.lastUpdated = lastUpdated
    }

    public static func disabled(configuration: HotReloadConfiguration = .disabled) -> HotReloadSnapshot {
        HotReloadSnapshot(
            state: .disabled,
            detail: "该配置未启用热更新。",
            configuration: configuration
        )
    }
}
