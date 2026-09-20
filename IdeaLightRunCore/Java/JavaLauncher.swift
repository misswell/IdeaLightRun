import Foundation

/// §58: 启动流水线：扫描 → 宏/Module/JDK 解析 → fingerprint → classpath（缓存判定）
/// → compile → LaunchPlan。GUI 与 CLI 共用，禁止另起一套（§4）。
public struct JavaLauncher: Sendable {
    public init() {}

    public func prepare(
        config: RunConfiguration,
        projectRoot: URL,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void,
        processHandle: ProcessHandle? = nil
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

        // ②③ JDK + 构建工具（§23/§15，与项目级构建共用 ProjectToolchain）
        let toolchain = try ProjectToolchain.resolve(
            projectRoot: projectRoot,
            result: result,
            configJDKName: config.jreReference,
            context: "启动",
            log: log
        )
        let jdk = toolchain.jdk

        let reactor = MavenPomReader.collectReactor(rootPom: toolchain.rootPomURL)
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

        let service = toolchain.service

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
                    handle: processHandle,
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
                handle: processHandle,
                log: log
            )

            // ⑦ LaunchPlan（§26）
            progress(.starting)
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
