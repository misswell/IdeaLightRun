import Foundation

/// §P0-10: IDEA 的 SHORTEN_COMMAND_LINE 语义。超长 classpath（典型 Spring Boot：
/// 上百个 jar 拼出 6 万+ 字符）会被 macOS 的 execve 参数上限（E2BIG）拒掉，
/// 必须改走不占命令行长度的载体。
public enum ShortenCommandLineMode: Equatable, Sendable {
    /// 原样 `-cp`，不缩短。
    case none
    /// 临时 manifest jar：Class-Path 列出全部条目，`-cp <jar>`。
    case jarManifest
    /// JDK 9+ @argfile：`-cp <内容>` 写进文件，`java @file Main`。
    /// （IDEA 的 CLASSPATH_FILE 与 ARGFILE 在 macOS 的 JDK 9+ 上等价；
    /// `-cp @file` 是 JBR 专属写法，标准 JDK 不支持。）
    case classpathFile
    /// 未设置 / AUTO：短 classpath 原样，超长自动选载体。
    case auto

    /// 自动模式判定阈值（字符数）。macOS 单参数上限约 256KB，整体约 1MB；
    /// 6 万字符留足余量，也覆盖绝大多数真实 Spring Boot 项目。
    public static let autoThreshold = 60_000

    /// IDEA 写 NONE / JAR_MANIFEST / CLASSPATH_FILE / ARGFILE / AUTO；
    /// 未知值按 auto 兜底——比 none 安全，不会把超长 classpath 送进 E2BIG。
    public static func parse(_ raw: String?) -> ShortenCommandLineMode {
        switch raw?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "NONE": return .none
        case "JAR_MANIFEST": return .jarManifest
        case "CLASSPATH_FILE", "ARGFILE": return .classpathFile
        default: return .auto
        }
    }
}
