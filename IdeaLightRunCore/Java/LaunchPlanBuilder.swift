import Foundation

/// §26–§29: 已解析的运行配置 + classpath + JDK → JavaLaunchPlan。
/// 宏展开、环境文件、Working Directory 校验都在 `RunConfigurationResolver` 完成，
/// 这里只做组装与最后的可执行性检查。
public enum LaunchPlanBuilder {
    public static func build(
        resolved: ResolvedRunConfiguration,
        classpath: [String],
        jdk: JDKInstallation
    ) throws -> JavaLaunchPlan {
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

        return JavaLaunchPlan(
            javaExecutable: javaExecutable,
            vmArguments: resolved.vmArguments,
            classpath: classpath,
            mainClass: mainClass,
            programArguments: resolved.programArguments,
            environment: resolved.environment,
            workingDirectory: resolved.workingDirectory
        )
    }

    /// 便捷入口：解析 + 组装。GUI 的预览/CLI 的单次调用与测试走这里；
    /// 完整启动流水线在 `JavaLauncher` 里分两步执行（先解析，classpath 就绪后再组装）。
    public static func build(
        config: RunConfiguration,
        projectRoot: URL,
        moduleDirectory: URL?,
        classpath: [String],
        jdk: JDKInstallation,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> JavaLaunchPlan {
        let module = moduleDirectory.map { ProjectModule(name: $0.lastPathComponent, directory: $0) }
        let resolved = try RunConfigurationResolver().resolve(
            config: config,
            projectRoot: projectRoot,
            module: module,
            jdk: jdk,
            parentEnvironment: parentEnvironment
        )
        return try build(resolved: resolved, classpath: classpath, jdk: jdk)
    }
}
