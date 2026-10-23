import Foundation

/// 热更新后端。自动只在「用户显式配置了可用的外部 Agent」时才选外部，
/// 否则用内置标准 HotSwap；检测到某个 Agent 文件存在不等于它已生效。
public enum HotReloadProviderKind: String, CaseIterable, Codable, Sendable {
    case automatic
    case standard
    case springBootDevTools
    case hotswapAgent
    case jrebel

    public var displayName: String {
        switch self {
        case .automatic: return "自动选择"
        case .standard: return "内置 HotSwap"
        case .springBootDevTools: return "Spring Boot DevTools"
        case .hotswapAgent: return "外部 HotswapAgent"
        case .jrebel: return "外部 JRebel"
        }
    }

    public var isExternalAgent: Bool {
        self == .hotswapAgent || self == .jrebel
    }

    /// 内置标准 HotSwap 的能力边界：只保证方法体替换。
    public var staticCapability: HotReloadCapability {
        switch self {
        case .automatic, .standard:
            return HotReloadCapability(
                provider: .standard,
                methodBody: .supported,
                structuralChanges: .unsupported,
                newClasses: .limited("新类可在下次被引用时加载，但不会自动注册为 Spring Bean"),
                springBeanRefresh: .unsupported,
                resources: .limited("资源写入输出目录；框架缓存是否刷新取决于框架"),
                note: "不开放 JDWP；标准 JVM 只能替换已加载类的方法体"
            )
        case .springBootDevTools:
            return HotReloadCapability(
                provider: .springBootDevTools,
                methodBody: .restart("通过 DevTools 快速重启生效"),
                structuralChanges: .restart("通过 DevTools 快速重启生效"),
                newClasses: .restart("通过 DevTools 快速重启生效"),
                springBeanRefresh: .restart("上下文重建后重新注册"),
                resources: .restart("classpath 变化触发快速重启"),
                note: "只适用于 classpath 启动且包含 spring-boot-devtools 的应用"
            )
        case .hotswapAgent:
            return HotReloadCapability(
                provider: .hotswapAgent,
                methodBody: .delegated,
                structuralChanges: .delegated,
                newClasses: .delegated,
                springBeanRefresh: .delegated,
                resources: .delegated,
                note: "能力由 HotswapAgent 版本与 JVM 增强支持决定；未验证前不宣称可用"
            )
        case .jrebel:
            return HotReloadCapability(
                provider: .jrebel,
                methodBody: .delegated,
                structuralChanges: .delegated,
                newClasses: .delegated,
                springBeanRefresh: .delegated,
                resources: .delegated,
                note: "使用你自己的 JRebel 授权与安装；IdeaLightRun 不捆绑商业组件"
            )
        }
    }
}

/// 热更新失败后的回退策略。默认「询问后重启」：不替用户擅自重启正在跑的服务。
public enum HotReloadRestartPolicy: String, CaseIterable, Codable, Sendable {
    case notify
    case ask
    case automatic

    public var displayName: String {
        switch self {
        case .notify: return "仅提示"
        case .ask: return "询问后重启"
        case .automatic: return "自动重启"
        }
    }
}

/// 每个 Run Configuration 独立的热更新设置。
/// 存在 Application Support 里，不写用户项目目录，也不改 IDEA 的 .run.xml。
public struct HotReloadConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: HotReloadProviderKind
    /// 保存源码后自动执行增量编译。
    public var autoCompileOnChange: Bool
    /// 监听编译输出目录，兼容 IDEA / 命令行等外部构建。
    public var watchCompiledOutputs: Bool
    public var watchResources: Bool
    public var restartPolicy: HotReloadRestartPolicy
    /// 短时间内的多次文件事件合并为一次编译。允许 200–10000 毫秒。
    public var debounceMilliseconds: Int
    /// 忽略的路径（绝对路径前缀或相对项目根的路径前缀）。
    public var ignoredPaths: [String]
    /// 外部 Agent 的 jar / dylib / 安装目录；仅 hotswapAgent / jrebel 使用。
    public var externalAgentPath: String?
    /// 追加给外部 Agent 的 JVM 参数原文（按空白分词后逐个传给 Process.arguments）。
    public var externalAgentArguments: String

    public init(
        enabled: Bool = false,
        provider: HotReloadProviderKind = .automatic,
        autoCompileOnChange: Bool = true,
        watchCompiledOutputs: Bool = true,
        watchResources: Bool = true,
        restartPolicy: HotReloadRestartPolicy = .ask,
        debounceMilliseconds: Int = 800,
        ignoredPaths: [String] = [],
        externalAgentPath: String? = nil,
        externalAgentArguments: String = ""
    ) {
        self.enabled = enabled
        self.provider = provider
        self.autoCompileOnChange = autoCompileOnChange
        self.watchCompiledOutputs = watchCompiledOutputs
        self.watchResources = watchResources
        self.restartPolicy = restartPolicy
        self.debounceMilliseconds = debounceMilliseconds
        self.ignoredPaths = ignoredPaths
        self.externalAgentPath = externalAgentPath
        self.externalAgentArguments = externalAgentArguments
    }

    public var isActive: Bool { enabled }

    public var normalized: HotReloadConfiguration {
        var copy = self
        copy.debounceMilliseconds = min(max(copy.debounceMilliseconds, 200), 10_000)
        copy.ignoredPaths = copy.ignoredPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return copy
    }

    public var effectiveDebounce: TimeInterval {
        TimeInterval(normalized.debounceMilliseconds) / 1000
    }

    public static let disabled = HotReloadConfiguration()
}

extension HotReloadConfiguration {
    /// 只保留对当前配置有意义的设置；目录监听开关全关时仍可手动触发。
    public var hasAnyWatcher: Bool {
        autoCompileOnChange || watchCompiledOutputs
    }
}

/// 宿主（GUI / CLI）按配置名提供热更新设置。Compound 的每个成员都经过
/// `ExecutionCoordinator`，因此成员能拿到自己的开关，而不是共用父配置的设置。
public typealias HotReloadConfigurationProvider = @Sendable (RunConfiguration) -> HotReloadConfiguration?
