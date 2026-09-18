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
             .launchFailed(let detail):
            return detail
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
            return "清除 classpath 缓存后重新解析。"
        case .mainClassNotFound:
            return "确认 Main Class 是否存在并已编译。"
        case .launchFailed:
            return "查看日志中的详细错误。"
        }
    }

    public var localizedDescription: String { "\(title)：\(reason)" }
}
