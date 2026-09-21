import Foundation

/// §109: 统一错误结构，每个错误提供 title / reason / suggestion。
public enum IdeaLightRunError: Error, Equatable, Sendable {
    case projectNotFound(path: String)
    case invalidProjectRoot(path: String)
    case invalidConfiguration(detail: String)
    case unresolvedMacro(detail: String)
    case moduleNotFound(detail: String)
    case jdkNotFound(detail: String)
    case buildToolNotFound(detail: String)
    case buildFailed(detail: String)
    case classpathResolveFailed(detail: String)
    case mainClassNotFound(detail: String)
    case launchFailed(detail: String)
    case launchCancelled(detail: String)
    /// §9: 配置类型本身不能执行时必须明说，不能退化成"启动失败"。
    case unsupportedConfiguration(detail: String)
    /// §10: Before Launch 不支持的任务不能偷偷忽略。
    case unsupportedBeforeLaunch(detail: String)
    /// §4.4: 环境文件缺失要报错，不能静默跳过。
    case environmentFileNotFound(path: String)
    /// §5: 依赖 IDEA 运行期上下文（$Prompt$ 等）的配置不允许启动。
    case unresolvedIdeaContextMacro(detail: String)
    /// §3.7: Before Launch 引用链成环。
    case beforeLaunchCycle(chain: [String])
    /// §3.7: Before Launch 引用的运行配置在项目里不存在。
    case referencedConfigurationNotFound(detail: String)
}

extension IdeaLightRunError {
    public var title: String {
        switch self {
        case .projectNotFound: return "项目不存在"
        case .invalidProjectRoot: return "不是有效的 Java 项目目录"
        case .invalidConfiguration: return "配置无效"
        case .unresolvedMacro: return "存在无法解析的宏"
        case .moduleNotFound: return "找不到 Module"
        case .jdkNotFound: return "找不到 JDK"
        case .buildToolNotFound: return "找不到构建工具"
        case .buildFailed: return "构建失败"
        case .classpathResolveFailed: return "Classpath 解析失败"
        case .mainClassNotFound: return "找不到 Main Class"
        case .launchFailed: return "启动失败"
        case .launchCancelled: return "已停止"
        case .unsupportedConfiguration: return "该配置类型暂不支持运行"
        case .unsupportedBeforeLaunch: return "Before Launch 任务无法执行"
        case .environmentFileNotFound: return "Environment File 不存在"
        case .unresolvedIdeaContextMacro: return "配置依赖 IDEA 当前上下文"
        case .beforeLaunchCycle: return "Before Launch 循环引用"
        case .referencedConfigurationNotFound: return "找不到被引用的运行配置"
        }
    }

    public var reason: String {
        switch self {
        case .projectNotFound(let path):
            return "路径不存在或不是目录：\(path)"
        case .invalidProjectRoot(let path):
            return "\(path) 下没有 .idea、pom.xml 或 build.gradle(.kts)"
        case .invalidConfiguration(let detail),
             .unresolvedMacro(let detail),
             .moduleNotFound(let detail),
             .jdkNotFound(let detail),
             .buildToolNotFound(let detail),
             .buildFailed(let detail),
             .classpathResolveFailed(let detail),
             .mainClassNotFound(let detail),
             .launchFailed(let detail),
             .launchCancelled(let detail),
             .unsupportedConfiguration(let detail),
             .unsupportedBeforeLaunch(let detail),
             .unresolvedIdeaContextMacro(let detail),
             .referencedConfigurationNotFound(let detail):
            return detail
        case .environmentFileNotFound(let path):
            return "Environment File Not Found：\(path)"
        case .beforeLaunchCycle(let chain):
            return "Before Launch configuration cycle detected: \(chain.joined(separator: " -> "))"
        }
    }

    public var suggestion: String {
        switch self {
        case .projectNotFound:
            return "请检查路径是否正确。"
        case .invalidProjectRoot:
            return "请选择包含 .idea 或 pom.xml / build.gradle 的项目根目录。"
        case .invalidConfiguration:
            return "请检查对应的 IDEA Run Configuration。"
        case .unresolvedMacro:
            return "请在 IdeaLightRun 中手动覆盖对应变量。"
        case .moduleNotFound:
            return "请确认模块名或 Main Class 是否正确。"
        case .jdkNotFound:
            return "请安装所需 JDK，或在 IdeaLightRun 设置中选择 JDK 目录。"
        case .buildToolNotFound:
            return "请安装 Maven/Gradle，或使用项目自带 Wrapper。"
        case .buildFailed:
            return "查看构建输出定位错误。"
        case .classpathResolveFailed:
            return "清除 classpath 缓存后重新解析；多模块项目若兄弟模块未 install，需要在配置里保留 Build（或先执行一次 Build Project）。"
        case .mainClassNotFound:
            return "确认 Main Class 是否存在并已编译。"
        case .launchFailed:
            return "查看日志中的详细错误。"
        case .launchCancelled:
            return "点击 Run 重新启动。"
        case .unsupportedConfiguration:
            return "请在 IDEA 中改用已支持的配置类型，或等待后续版本支持。"
        case .unsupportedBeforeLaunch:
            return "请在 IDEA 的 Before Launch 中移除该任务，或改用 IdeaLightRun 的项目级构建。"
        case .environmentFileNotFound:
            return "请确认环境文件路径存在（$PROJECT_DIR$ / $MODULE_DIR$ 展开后仍能找到）。"
        case .unresolvedIdeaContextMacro:
            return "该配置依赖 IDEA 当前上下文，IdeaLightRun 无法自动解析；请在 IDEA 中把对应值改成字面量。"
        case .beforeLaunchCycle:
            return "请打破 Before Launch 的相互引用后再运行。"
        case .referencedConfigurationNotFound:
            return "请确认被引用的运行配置名拼写正确，且存在于同一项目。"
        }
    }

    public var localizedDescription: String { "\(title)：\(reason)" }
}
