import Foundation

/// §26–§29 + §7: 已解析的运行配置 + classpath + JDK → 通用启动计划。
///
/// Java 特有的 `-cp` / Main Class 拼装只发生在这一处；再往下（`ManagedProcessSession`、
/// GUI、CLI）只看到可执行文件与参数，因此 JAR / Maven / Gradle 计划能复用同一条进程管线。
/// 宏展开、环境文件、Working Directory 校验在 `RunConfigurationResolver` 完成。
public enum JavaRunPlanner {
    public static func plan(
        resolved: ResolvedRunConfiguration,
        classpath: [String],
        jdk: JDKInstallation
    ) throws -> ExecutableLaunchPlan {
        guard let mainClass = resolved.mainClass, !mainClass.isEmpty else {
            throw IdeaLightRunError.mainClassNotFound(detail: "配置 “\(resolved.source.name)” 没有可用的 Main Class。")
        }

        let javaExecutable = jdk.javaExecutable
        guard FileManager.default.isExecutableFile(atPath: javaExecutable.path) else {
            throw IdeaLightRunError.jdkNotFound(detail: "Java 可执行文件不存在：\(javaExecutable.path)")
        }

        guard !classpath.isEmpty else {
            throw IdeaLightRunError.classpathResolveFailed(detail: "runtime classpath 为空，无法启动。")
        }

        // §27: classpath 以 ":" 连接后通过 -cp 传递（@argfile 支持在 P1，§112）。
        return ExecutableLaunchPlan(
            executable: javaExecutable,
            arguments: resolved.vmArguments
                + ["-cp", classpath.joined(separator: ":"), mainClass]
                + resolved.programArguments,
            environment: resolved.environment,
            workingDirectory: resolved.workingDirectory
        )
    }
}
