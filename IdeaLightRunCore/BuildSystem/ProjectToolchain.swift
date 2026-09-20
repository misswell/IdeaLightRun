import Foundation

/// §4: 启动流水线与项目级构建共用的工具链解析（JDK → Maven），
/// 避免两处各写一份定位逻辑导致行为与报错文案漂移。
public struct ProjectToolchain: Sendable {
    public let result: ScanResult
    public let jdk: JDKInstallation
    public let maven: MavenLocator.Candidate
    public let rootPomURL: URL
    public let service: MavenBuildService

    /// 从已有扫描结果解析（启动流水线已扫描过，不重复扫）。
    public static func resolve(
        projectRoot: URL,
        result: ScanResult,
        configJDKName: String? = nil,
        context: String,
        log: @escaping LogCallback
    ) throws -> ProjectToolchain {
        // §15: 构建系统（当前 Maven；Gradle 在 Milestone 4）
        guard let detection = result.buildSystem.maven else {
            throw IdeaLightRunError.buildToolNotFound(
                detail: "当前版本仅支持 Maven 项目直接\(context)；Gradle 支持在 Milestone 4 提供。"
            )
        }

        // §23: 项目级构建没有 Run Configuration，此时 JDK 取 .idea 项目 SDK → JAVA_HOME → 系统。
        let jdkResolution = JDKResolver().resolve(
            configJDKName: configJDKName,
            projectJDKName: result.projectJDKName
        )
        guard let jdk = jdkResolution.installation else {
            let detail = jdkResolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.jdkNotFound(detail: detail.isEmpty ? "未找到可用 JDK。" : detail)
        }
        log(LogLine(stream: .system, text: "[IdeaLightRun] JDK: \(jdk.displayName ?? jdk.home.lastPathComponent) (major \(jdk.majorVersion.map(String.init) ?? "?"))"))

        // §15: GUI 从 Dock 启动时 PATH 不含用户安装的 Maven，按绝对路径候选枚举。
        let locator = MavenLocator(projectRoot: projectRoot)
        guard let maven = locator.firstUsable() else {
            throw IdeaLightRunError.buildToolNotFound(detail: locator.failureDetail())
        }
        log(LogLine(stream: .system, text: "[IdeaLightRun] Maven: \(maven.executable.path)（\(maven.source.label)）"))

        return ProjectToolchain(
            result: result,
            jdk: jdk,
            maven: maven,
            rootPomURL: detection.pomURL,
            service: MavenBuildService(
                projectRoot: projectRoot,
                mavenExecutable: maven.executable,
                environment: MavenBuildService.buildEnvironment(javaHome: jdk.home)
            )
        )
    }

    /// 自行扫描后解析（CLI 与项目级构建入口）。
    public static func resolveMaven(
        projectRoot: URL,
        configJDKName: String? = nil,
        context: String,
        log: @escaping LogCallback
    ) throws -> ProjectToolchain {
        try resolve(
            projectRoot: projectRoot,
            result: try IntelliJProjectScanner().scan(projectRoot: projectRoot),
            configJDKName: configJDKName,
            context: context,
            log: log
        )
    }
}
