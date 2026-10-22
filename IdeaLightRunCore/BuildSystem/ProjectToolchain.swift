import Foundation

/// §4: 启动流水线与项目级构建共用的工具链解析（JDK → Maven / Gradle），
/// 避免两处各写一份定位逻辑导致行为与报错文案漂移。
/// 选中的适配器由 `BuildSystemSelector` 决定，调用方只面对 `BuildSystemAdapter`。
public struct ProjectToolchain: Sendable {
    public let result: ScanResult
    public let jdk: JDKInstallation
    public let kind: BuildSystemKind
    public let adapter: any BuildSystemAdapter

    /// classpath 缓存身份由适配器给出（Maven artifactId / Gradle project path）。
    public func target(for module: ProjectModule, includeProvided: Bool) -> BuildTarget {
        BuildTarget(
            module: module,
            variant: adapter.classpathVariant(for: module, includeProvided: includeProvided)
        )
    }

    /// 从已有扫描结果解析（启动流水线已扫描过，不重复扫）。
    public static func resolve(
        projectRoot: URL,
        result: ScanResult,
        config: RunConfiguration? = nil,
        configJDKName: String? = nil,
        context: String,
        log: @escaping LogCallback
    ) throws -> ProjectToolchain {
        // §15/§P0-2: Maven 与 Gradle 同时存在时不得靠调用顺序决定；
        // 选择规则收敛在 BuildSystemSelector，Maven 运行配置不会落到 Gradle。
        let selection = BuildSystemSelector.select(
            config: config,
            detection: result.buildSystem,
            modules: result.modules
        )
        if selection.isAmbiguous {
            log(LogLine(stream: .system, text: "[IdeaLightRun] 警告：\(selection.reason)"))
        }
        guard let kind = selection.kind else {
            throw IdeaLightRunError.buildToolNotFound(
                detail: "\(selection.reason)\nIdeaLightRun 无法\(context)该项目。"
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

        switch kind {
        case .maven:
            guard let detection = result.buildSystem.maven else {
                throw IdeaLightRunError.buildToolNotFound(
                    detail: "\(selection.reason)\nIdeaLightRun 无法\(context)该项目。"
                )
            }
            // §15: GUI 从 Dock 启动时 PATH 不含用户安装的 Maven，按绝对路径候选枚举。
            let locator = MavenLocator(projectRoot: projectRoot)
            guard let maven = locator.firstUsable() else {
                throw IdeaLightRunError.buildToolNotFound(
                    detail: "\(locator.failureDetail())\nIdeaLightRun 无法\(context)该项目。"
                )
            }
            log(LogLine(stream: .system, text: "[IdeaLightRun] Maven: \(maven.executable.path)（\(maven.source.label)）"))
            return ProjectToolchain(
                result: result,
                jdk: jdk,
                kind: .maven,
                adapter: MavenBuildService(
                    projectRoot: projectRoot,
                    rootPomURL: detection.pomURL,
                    mavenExecutable: maven.executable,
                    environment: MavenBuildService.buildEnvironment(javaHome: jdk.home),
                    jdkMajorVersion: jdk.majorVersion
                )
            )

        case .gradle:
            guard let detection = result.buildSystem.gradle else {
                throw IdeaLightRunError.buildToolNotFound(
                    detail: "\(selection.reason)\nIdeaLightRun 无法\(context)该项目。"
                )
            }
            // 项目自带 gradlew 优先：wrapper 锁定了项目声明的 Gradle 版本。
            let locator = GradleLocator(projectRoot: projectRoot)
            guard let gradle = locator.firstUsable() else {
                throw IdeaLightRunError.buildToolNotFound(
                    detail: "\(locator.failureDetail())\nIdeaLightRun 无法\(context)该项目。"
                )
            }
            log(LogLine(stream: .system, text: "[IdeaLightRun] Gradle: \(gradle.executable.path)（\(gradle.source.label)）"))
            return ProjectToolchain(
                result: result,
                jdk: jdk,
                kind: .gradle,
                adapter: GradleBuildService(
                    projectRoot: projectRoot,
                    settingsURL: detection.settingsURL,
                    modules: result.modules,
                    gradleExecutable: gradle.executable,
                    environment: GradleBuildService.buildEnvironment(javaHome: jdk.home),
                    jdkMajorVersion: jdk.majorVersion
                )
            )
        }
    }

    /// 自行扫描后解析（CLI 与项目级构建入口）。
    public static func resolveForProjectBuild(
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
