import Foundation

/// §58: 启动流水线：扫描 → 宏/Module/JDK 解析 → fingerprint → classpath（缓存判定）
/// → compile → LaunchPlan。GUI 与 CLI 共用，禁止另起一套（§4）。
public struct JavaLauncher: Sendable {
    public init() {}

    public func prepare(
        config: RunConfiguration,
        projectRoot: URL,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void
    ) async throws -> JavaLaunchPlan {
        let scanner = IntelliJProjectScanner()
        let result = try scanner.scan(projectRoot: projectRoot)

        // ① Module 解析（§13）
        let moduleResolution = ModuleResolver.resolveModule(
            named: config.moduleName,
            mainClass: config.mainClass,
            projectRoot: projectRoot,
            knownModules: result.modules
        )
        guard let module = moduleResolution.module else {
            let detail = moduleResolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.moduleNotFound(detail: detail.isEmpty ? "无法定位 module。" : detail)
        }

        // ② JDK 解析（§23）
        let jdkResolution = JDKResolver().resolve(
            configJDKName: config.jreReference,
            projectJDKName: result.projectJDKName
        )
        guard let jdk = jdkResolution.installation else {
            let detail = jdkResolution.warnings.map(\.detail).joined(separator: "；")
            throw IdeaLightRunError.jdkNotFound(detail: detail.isEmpty ? "未找到可用 JDK。" : detail)
        }
        log(LogLine(stream: .system, text: "[IdeaLightRun] JDK: \(jdk.displayName ?? jdk.home.lastPathComponent) (major \(jdk.majorVersion.map(String.init) ?? "?"))"))

        // ③ 构建系统（当前 Maven；Gradle 在 Milestone 4）
        guard let maven = result.buildSystem.maven else {
            throw IdeaLightRunError.buildToolNotFound(detail: "当前版本仅支持 Maven 项目直接启动；Gradle 支持在 Milestone 4 提供。")
        }
        guard let mavenExecutable = MavenBuildService.discoverMavenExecutable(projectRoot: projectRoot) else {
            throw IdeaLightRunError.buildToolNotFound(detail: "找不到 Maven：项目没有可执行的 mvnw，PATH 中也没有 mvn。")
        }
        log(LogLine(stream: .system, text: "[IdeaLightRun] Maven: \(mavenExecutable.path)"))

        let reactor = MavenPomReader.collectReactor(rootPom: maven.pomURL)
        let reactorModule = reactor.first { $0.directory.standardizedFileURL == module.directory.standardizedFileURL }
            ?? reactor.first { $0.artifactId == module.name }
        // reactor 中存在非根模块即视为多模块（§16）
        let isMultiModule = reactor.contains { $0.directory.standardizedFileURL != projectRoot.standardizedFileURL }
        let reactorModuleName: String? = {
            guard isMultiModule else { return nil }
            guard let info = reactorModule else { return nil }
            // 根模块本身不需要 -pl
            if info.directory.standardizedFileURL == projectRoot.standardizedFileURL { return nil }
            return info.artifactId
        }()

        let service = MavenBuildService(
            projectRoot: projectRoot,
            mavenExecutable: mavenExecutable,
            environment: MavenBuildService.buildEnvironment(javaHome: jdk.home)
        )

        // ④ §42: 同项目串行构建
        let plan = try await BuildGate.shared.run(projectKey: projectRoot.standardizedFileURL.path) {
            // ⑤ classpath：缓存命中 or Cold Resolve（§18/§19）
            progress(.resolvingClasspath)
            let fingerprint = ClasspathCache.mavenFingerprint(
                projectRoot: projectRoot,
                reactorPoms: reactor.map(\.pomURL),
                jdkMajor: jdk.majorVersion
            )
            var classpath: [String]
            if let cached = ClasspathCache.load(projectRoot: projectRoot, moduleName: module.name),
               cached.fingerprint == fingerprint {
                classpath = cached.entries
                log(LogLine(stream: .system, text: "[IdeaLightRun] classpath 命中缓存（\(classpath.count) 项）"))
            } else {
                log(LogLine(stream: .system, text: "[IdeaLightRun] 解析 runtime classpath（pom/JDK 变化或首次运行）…"))
                let outputFile = ClasspathCache.mavenOutputFileURL(projectRoot: projectRoot, moduleName: module.name)
                let rawEntries = try service.resolveRuntimeClasspath(
                    reactorModuleName: reactorModuleName,
                    hasModules: isMultiModule,
                    outputFile: outputFile,
                    log: log
                )
                classpath = MavenClasspathResolver.normalize(
                    entries: rawEntries,
                    reactor: reactor,
                    targetModuleDirectory: module.directory
                )
                ClasspathCache.store(
                    CachedClasspath(module: module.name, entries: classpath, fingerprint: fingerprint, resolvedAt: Date()),
                    projectRoot: projectRoot,
                    moduleName: module.name
                )
                log(LogLine(stream: .system, text: "[IdeaLightRun] classpath 解析完成（\(classpath.count) 项），已缓存"))
            }

            // ⑥ 编译（§17：不 clean；§59：每次启动增量 compile）
            progress(.building)
            log(LogLine(stream: .system, text: "[IdeaLightRun] 编译 \(reactorModuleName ?? module.name) …"))
            try service.compile(
                reactorModuleName: reactorModuleName,
                hasModules: isMultiModule,
                log: log
            )

            // ⑦ LaunchPlan（§26）
            progress(.preparing)
            return try LaunchPlanBuilder.build(
                config: config,
                projectRoot: projectRoot,
                moduleDirectory: module.directory,
                classpath: classpath,
                jdk: jdk
            )
        }
        return plan
    }
}
