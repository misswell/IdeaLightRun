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

        // §P0-10: 超长 classpath 会被 execve 的 E2BIG 拒掉。按配置声明的
        // SHORTEN_COMMAND_LINE（未设置按 AUTO）选载体，产物登记进 temporaryArtifacts，
        // 进程进入终态后由会话删除。
        let mode = ShortenCommandLineMode.parse(resolved.source.rawOptions["SHORTEN_COMMAND_LINE"])
        let joinedClasspath = classpath.joined(separator: ":")

        switch mode {
        case .jarManifest:
            return try manifestJarPlan(
                resolved: resolved, classpath: classpath, joined: joinedClasspath,
                mainClass: mainClass, javaExecutable: javaExecutable
            )
        case .classpathFile:
            return try argfilePlan(
                resolved: resolved, joined: joinedClasspath,
                mainClass: mainClass, javaExecutable: javaExecutable
            )
        case .none:
            return plainPlan(resolved: resolved, joined: joinedClasspath, mainClass: mainClass, javaExecutable: javaExecutable)
        case .auto:
            if joinedClasspath.count <= ShortenCommandLineMode.autoThreshold {
                return plainPlan(resolved: resolved, joined: joinedClasspath, mainClass: mainClass, javaExecutable: javaExecutable)
            }
            // JDK 9+ 走 @argfile；JDK 8（或版本未知）没有 @argfile，退到 manifest jar。
            if let major = jdk.majorVersion, major >= 9 {
                return try argfilePlan(resolved: resolved, joined: joinedClasspath, mainClass: mainClass, javaExecutable: javaExecutable)
            }
            return try manifestJarPlan(
                resolved: resolved, classpath: classpath, joined: joinedClasspath,
                mainClass: mainClass, javaExecutable: javaExecutable
            )
        }
    }

    // MARK: - 三种载体

    private static func plainPlan(
        resolved: ResolvedRunConfiguration,
        joined: String,
        mainClass: String,
        javaExecutable: URL
    ) -> ExecutableLaunchPlan {
        ExecutableLaunchPlan(
            executable: javaExecutable,
            arguments: resolved.vmArguments + ["-cp", joined, mainClass] + resolved.programArguments,
            environment: resolved.environment,
            workingDirectory: resolved.workingDirectory
        )
    }

    /// `java @argfile Main`：argfile 里是 `-cp "<classpath>"`（JDK 9+ 语法，
    /// 参数内含空格时用引号包住整体）。
    private static func argfilePlan(
        resolved: ResolvedRunConfiguration,
        joined: String,
        mainClass: String,
        javaExecutable: URL
    ) throws -> ExecutableLaunchPlan {
        let file = try LaunchArtifactStore.makeArtifactURL(suffix: ".argfile")
        try Data("-cp \"\(joined)\"".utf8).write(to: file, options: .atomic)
        return ExecutableLaunchPlan(
            executable: javaExecutable,
            arguments: resolved.vmArguments + ["@\(file.path)", mainClass] + resolved.programArguments,
            environment: resolved.environment,
            workingDirectory: resolved.workingDirectory,
            temporaryArtifacts: [file]
        )
    }

    /// `java -cp <manifest-jar> Main`：依赖全在 manifest 的 Class-Path 里。
    private static func manifestJarPlan(
        resolved: ResolvedRunConfiguration,
        classpath: [String],
        joined: String,
        mainClass: String,
        javaExecutable: URL
    ) throws -> ExecutableLaunchPlan {
        let jar = try LaunchArtifactStore.makeArtifactURL(suffix: ".jar")
        try ManifestClasspathJar.write(classpath: classpath, to: jar)
        return ExecutableLaunchPlan(
            executable: javaExecutable,
            arguments: resolved.vmArguments + ["-cp", jar.path, mainClass] + resolved.programArguments,
            environment: resolved.environment,
            workingDirectory: resolved.workingDirectory,
            temporaryArtifacts: [jar]
        )
    }
}
