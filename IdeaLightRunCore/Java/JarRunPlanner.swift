import Foundation

/// §5.2: JAR Application 的启动计划。
/// IDEA 的 JarApplicationCommandLineState 走 `java [VM_OPTIONS] -jar <JAR_PATH> [PROGRAM_ARGUMENTS]`，
/// 不经过 `-cp` / Main Class，也不解析项目 classpath。
public enum JarRunPlanner {
    public static func plan(
        resolved: ResolvedRunConfiguration,
        jdk: JDKInstallation
    ) throws -> ExecutableLaunchPlan {
        guard let jarPath = resolved.jarPath else {
            throw IdeaLightRunError.invalidConfiguration(
                detail: "配置 “\(resolved.source.name)” 没有 JAR Path，无法启动。"
            )
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: jarPath.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw IdeaLightRunError.jarNotFound(path: jarPath.path)
        }
        guard FileManager.default.isReadableFile(atPath: jarPath.path) else {
            throw IdeaLightRunError.invalidConfiguration(
                detail: "JAR 文件不可读取：\(jarPath.path)"
            )
        }

        let javaExecutable = jdk.javaExecutable
        guard FileManager.default.isExecutableFile(atPath: javaExecutable.path) else {
            throw IdeaLightRunError.jdkNotFound(detail: "Java 可执行文件不存在：\(javaExecutable.path)")
        }

        return ExecutableLaunchPlan(
            executable: javaExecutable,
            arguments: resolved.vmArguments + ["-jar", jarPath.path] + resolved.programArguments,
            environment: resolved.environment,
            workingDirectory: resolved.workingDirectory
        )
    }
}
