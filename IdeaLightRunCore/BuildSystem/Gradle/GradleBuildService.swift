import Foundation

/// 一个 Gradle 子项目：project path 是 Gradle 的唯一身份（":library:util"），
/// 目录只用于编辑与指纹采集。
public struct GradleProject: Equatable, Sendable {
    public var path: String
    public var name: String
    public var directory: URL

    public init(path: String, name: String, directory: URL) {
        self.path = path
        self.name = name
        self.directory = directory
    }
}

/// §9: Gradle 适配器。
///
/// - 构建/运行与 Maven 共用 `BuildSystemAdapter`，启动流水线不写 `if Gradle`
/// - 项目内编译：`:module:classes`（Gradle 会按 task graph 先构建项目依赖）
/// - 项目级 Build / Rebuild / Clean：`classes` / `clean classes` / `clean`，
///   按任务名作用于根项目与所有子项目
/// - classpath 由生成的 init script 读取 `sourceSets.main.runtimeClasspath`
///   （includeProvided 时再并入 `compileClasspath`），不重写依赖解析
public struct GradleBuildService: BuildSystemAdapter, Sendable {
    public let projectRoot: URL
    public let gradleExecutable: URL
    public let environment: [String: String]
    /// §57: JDK major 参与 classpath 指纹。
    public let jdkMajorVersion: Int?
    public let gradleUserHome: URL
    public let projects: [GradleProject]

    public init(
        projectRoot: URL,
        settingsURL: URL?,
        modules: [ProjectModule] = [],
        gradleExecutable: URL,
        environment: [String: String],
        jdkMajorVersion: Int? = nil,
        gradleUserHome: URL? = nil
    ) {
        self.projectRoot = projectRoot
        self.gradleExecutable = gradleExecutable
        self.environment = environment
        self.jdkMajorVersion = jdkMajorVersion
        self.gradleUserHome = gradleUserHome ?? Self.resolveGradleUserHome(environment: environment)
        self.projects = Self.projectIndex(
            projectRoot: projectRoot,
            settingsURL: settingsURL,
            modules: modules
        )
    }

    /// 构建/解析共用的 Gradle 环境：JAVA_HOME 指向解析出的 JDK。
    public static func buildEnvironment(javaHome: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let javaHome {
            env["JAVA_HOME"] = javaHome.path
        }
        return env
    }

    public static func resolveGradleUserHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let value = environment["GRADLE_USER_HOME"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".gradle", isDirectory: true)
    }

    // MARK: - 项目索引

    /// settings.gradle(.kts) 的 include + projectDir 映射是 Gradle 的唯一事实来源；
    /// `.iml` 解析出的模块用来补齐 settings 里读不到的自定义项目。
    static func projectIndex(
        projectRoot: URL,
        settingsURL: URL?,
        modules: [ProjectModule]
    ) -> [GradleProject] {
        var result: [GradleProject] = []
        var seenPaths = Set<String>()

        func add(path rawPath: String, name: String, directory: URL) {
            let path = normalizePath(rawPath)
            guard seenPaths.insert(path).inserted else { return }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(GradleProject(
                path: path,
                name: trimmedName.isEmpty ? (path == ":" ? projectRoot.lastPathComponent : path) : trimmedName,
                directory: directory
            ))
        }

        let info = settingsURL.map(GradleSettingsReader.read)
        let rootName = info?.rootProjectName?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? projectRoot.lastPathComponent
        add(path: ":", name: rootName, directory: projectRoot)

        if let info {
            for rawPath in info.includedProjects {
                let path = normalizePath(rawPath)
                let components = path
                    .drop(while: { $0 == ":" })
                    .split(separator: ":")
                    .map(String.init)
                guard let name = components.last, !name.isEmpty else { continue }
                let directory: URL
                if let mapped = info.projectDirectories[path], !mapped.isEmpty {
                    directory = mapped.hasPrefix("/")
                        ? URL(fileURLWithPath: mapped, isDirectory: true)
                        : projectRoot.appendingPathComponent(mapped, isDirectory: true)
                } else {
                    directory = components.reduce(projectRoot) {
                        $0.appendingPathComponent($1, isDirectory: true)
                    }
                }
                add(path: path, name: name, directory: directory)
            }
        }

        for module in modules {
            guard let rawPath = module.gradlePath, !rawPath.isEmpty else { continue }
            add(path: rawPath, name: module.name, directory: module.directory)
        }

        return result
    }

    static func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ":" }
        let components = trimmed
            .drop(while: { $0 == ":" })
            .split(separator: ":")
            .map(String.init)
        return components.isEmpty ? ":" : ":" + components.joined(separator: ":")
    }

    /// 运行配置里的 module 名可能来自 `.iml`，没有 gradlePath；依次按目录、名字、
    /// 相对路径映射到 Gradle project path。映射不出来时交给 Gradle 报“项目不存在”，
    /// 不静默改跑到根项目上。
    func gradlePath(for module: ProjectModule) -> String {
        let directory = module.directory.standardizedFileURL
        if directory.path == projectRoot.standardizedFileURL.path {
            return ":"
        }

        if let rawPath = module.gradlePath, !rawPath.isEmpty {
            let path = Self.normalizePath(rawPath)
            if path != ":" || directory.path == projectRoot.standardizedFileURL.path {
                return path
            }
        }
        if let match = projects.first(where: { $0.directory.standardizedFileURL == directory }) {
            return match.path
        }
        if let match = projects.first(where: { $0.name == module.name }) {
            return match.path
        }

        let rootPath = projectRoot.standardizedFileURL.path
        guard directory.path.hasPrefix(rootPath + "/") else { return ":" }
        let relative = directory.path.dropFirst(rootPath.count + 1)
        guard !relative.isEmpty else { return ":" }
        return ":" + relative.split(separator: "/").joined(separator: ":")
    }

    // MARK: - BuildSystemAdapter（§9）

    public func classpathVariant(for module: ProjectModule, includeProvided: Bool) -> ClasspathVariant {
        .gradle(module: gradlePath(for: module), includeProvided: includeProvided)
    }

    /// §3.3: Make / Build = 编译目标项目；Gradle 会先构建项目依赖。
    public func buildModule(
        _ target: BuildTarget,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        let path = gradlePath(for: target.module)
        let tasks = [Self.taskPath(path, "classes")]
        log(LogLine(stream: .system, text: "[IdeaLightRun] Gradle 编译 \(displayPath(path)) …"))
        let status = try run(arguments: Self.commandArguments(tasks: tasks), handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(
                detail: "Gradle \(tasks.joined(separator: " ")) 失败（退出码 \(status)），详见控制台输出。"
            )
        }
    }

    /// Build = `classes`；Rebuild = `clean classes`；Clean = `clean`。
    /// 任务按名字从根项目下发，Gradle 会作用于所有拥有该任务的子项目。
    public func buildProject(kind: ProjectBuildKind, handle: ProcessHandle?, log: @escaping LogCallback) throws {
        let tasks = Self.projectTasks(for: kind)
        log(LogLine(stream: .system, text: "[IdeaLightRun] Gradle \(tasks.joined(separator: " ")) …"))
        let status = try run(arguments: Self.commandArguments(tasks: tasks), handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(
                detail: "Gradle \(tasks.joined(separator: " ")) 失败（退出码 \(status)），详见\(kind.actionName)输出。"
            )
        }
    }

    /// §3.2: Gradle Before Launch 任务原文按参数逐项传递（§27），在项目根执行。
    /// `pomFile` 是 Maven 任务的字段，Gradle 没有对应语义；`moduleDirectory`
    /// 也不参与定位——Gradle 任务自身就是 project path。
    public func runTasks(
        _ tasks: [String],
        pomFile: String?,
        moduleDirectory: URL,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        guard !tasks.isEmpty else {
            throw IdeaLightRunError.unsupportedBeforeLaunch(detail: "Gradle Before Launch 任务为空。")
        }
        let status = try run(arguments: Self.commandArguments(tasks: tasks), handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(
                detail: "Gradle \(tasks.joined(separator: " ")) 失败（退出码 \(status)），详见控制台输出。"
            )
        }
    }

    public func hasFreshClasspathCache(for target: BuildTarget) -> Bool {
        guard let cached = ClasspathCache.load(projectRoot: projectRoot, variant: target.variant) else {
            return false
        }
        return ClasspathCache.validate(cached, fingerprint: fingerprint()) == .usable
    }

    public func runtimeClasspath(
        _ target: BuildTarget,
        withBuild: Bool,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws -> [String] {
        let current = fingerprint()
        if let cached = ClasspathCache.load(projectRoot: projectRoot, variant: target.variant) {
            switch ClasspathCache.validate(cached, fingerprint: current) {
            case .usable:
                if withBuild {
                    try buildModule(target, handle: handle, log: log)
                }
                log(LogLine(stream: .system, text: "[IdeaLightRun] classpath 命中缓存（\(cached.entries.count) 项）"))
                return cached.entries
            case .entriesMissing(let missing):
                log(LogLine(
                    stream: .system,
                    text: "[IdeaLightRun] 缓存的 classpath 有 \(missing.count) 项已不存在（如 clean 之后），重新解析…"
                ))
            case .stale, .empty:
                break
            }
        }

        log(LogLine(stream: .system, text: "[IdeaLightRun] 解析 runtime classpath（构建脚本/JDK 变化或首次运行）…"))
        let path = gradlePath(for: target.module)
        let output = ClasspathCache.gradleOutputFileURL(projectRoot: projectRoot, variant: target.variant)
        let initScript = ClasspathCache.gradleInitScriptURL(projectRoot: projectRoot, variant: target.variant)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.initScript.write(to: initScript, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: output)

        var tasks: [String] = []
        if withBuild {
            // 编译与解析合并成一次调用：冷启动只启动一个 Gradle 进程。
            tasks.append(Self.taskPath(path, "classes"))
        }
        tasks.append(Self.taskPath(path, "ideaLightRunClasspath"))

        let arguments = Self.commandArguments(
            tasks: tasks,
            systemProperties: [
                "idealightrun.classpath.file": output.path,
                "idealightrun.include.provided": target.variant.includeProvided ? "true" : "false",
            ],
            initScript: initScript
        )
        let status = try run(arguments: arguments, handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.classpathResolveFailed(
                detail: "Gradle \(tasks.joined(separator: " ")) 失败（退出码 \(status)），详见控制台输出。"
            )
        }
        guard let content = try? String(contentsOf: output, encoding: .utf8) else {
            throw IdeaLightRunError.classpathResolveFailed(
                detail: "Gradle 未生成 classpath 输出文件：\(output.path)"
            )
        }
        let entries = Self.splitClasspath(content)
        guard !entries.isEmpty else {
            throw IdeaLightRunError.classpathResolveFailed(
                detail: "Gradle 项目 \(displayPath(path)) 没有 main source set，无法解析运行 classpath。"
                    + "请确认该项目应用了 Java / Kotlin / Spring Boot 插件。"
            )
        }

        ClasspathCache.store(
            CachedClasspath(
                module: target.module.name,
                entries: entries,
                fingerprint: current,
                resolvedAt: Date()
            ),
            projectRoot: projectRoot,
            variant: target.variant
        )
        log(LogLine(stream: .system, text: "[IdeaLightRun] classpath 解析完成（\(entries.count) 项），已缓存"))
        return entries
    }

    // MARK: - 参数（可单测）

    static func projectTasks(for kind: ProjectBuildKind) -> [String] {
        switch kind {
        case .build: return ["classes"]
        case .rebuild: return ["clean", "classes"]
        case .clean: return ["clean"]
        }
    }

    static func taskPath(_ projectPath: String, _ task: String) -> String {
        projectPath == ":" ? ":\(task)" : "\(projectPath):\(task)"
    }

    /// 参数顺序固定，日志里能按原文复现。`--no-daemon` 保证 Stop 杀掉的
    /// 就是正在构建的进程，而不是只断开一个把构建留在后台的客户端。
    static func commandArguments(
        tasks: [String],
        systemProperties: [String: String] = [:],
        initScript: URL? = nil
    ) -> [String] {
        var arguments: [String] = []
        for key in systemProperties.keys.sorted() {
            arguments.append("-D\(key)=\(systemProperties[key] ?? "")")
        }
        arguments.append("--console=plain")
        arguments.append("--no-daemon")
        if let initScript {
            arguments.append("--init-script")
            arguments.append(initScript.path)
        }
        arguments.append(contentsOf: tasks)
        return arguments
    }

    static func splitClasspath(_ content: String) -> [String] {
        var seen = Set<String>()
        return content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - classpath init script

    /// 只注册任务、不在配置阶段读 source set；任务执行时才解析 runtimeClasspath。
    /// 兼容 settings-only 项目与 Kotlin DSL，不需要项目自己引入任何插件。
    static let initScript = """
    allprojects { project ->
        def taskName = "ideaLightRunClasspath"
        if (project.tasks.findByName(taskName) == null) {
            project.tasks.register(taskName) {
                doLast {
                    def sourceSets = project.extensions.findByName("sourceSets")
                    def main = sourceSets?.findByName("main")
                    def output = new File(System.getProperty("idealightrun.classpath.file"))
                    output.getParentFile()?.mkdirs()
                    if (main == null) {
                        output.text = ""
                        return
                    }
                    def entries = new LinkedHashSet()
                    entries.addAll(main.runtimeClasspath.files.collect { it.absolutePath })
                    if (System.getProperty("idealightrun.include.provided") == "true") {
                        entries.addAll(main.compileClasspath.files.collect { it.absolutePath })
                    }
                    output.text = entries.join("\\n")
                }
            }
        }
    }

    """

    // MARK: - 内部

    private func displayPath(_ path: String) -> String {
        path == ":" ? "根项目" : path
    }

    private func fingerprint() -> String {
        ClasspathCache.gradleFingerprint(
            projectRoot: projectRoot,
            buildFiles: buildFiles(),
            jdkMajor: jdkMajorVersion,
            gradleUserHome: gradleUserHome
        )
    }

    /// settings / 各项目构建脚本 / version catalog / buildSrc / 根 gradle.properties。
    /// wrapper properties 与全局配置由 `ClasspathCache.gradleFingerprint` 统一纳入。
    func buildFiles() -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        func add(_ url: URL) {
            if fm.fileExists(atPath: url.path) {
                files.append(url)
            }
        }

        for name in ["settings.gradle", "settings.gradle.kts", "gradle.properties"] {
            add(projectRoot.appendingPathComponent(name))
        }
        add(projectRoot.appendingPathComponent("gradle/libs.versions.toml"))
        for name in ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"] {
            add(projectRoot.appendingPathComponent("buildSrc/\(name)"))
        }
        for project in projects {
            for name in ["build.gradle", "build.gradle.kts"] {
                add(project.directory.appendingPathComponent(name))
            }
        }
        return files
    }

    private func run(arguments: [String], handle: ProcessHandle?, log: @escaping LogCallback) throws -> Int32 {
        try BuildProcessRunner.run(
            executable: gradleExecutable,
            arguments: arguments,
            workingDirectory: projectRoot,
            environment: environment,
            handle: handle,
            log: log
        )
    }
}
