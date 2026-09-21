import Foundation

/// §18/§6.2: Maven classpath 取哪一段依赖。
/// - `.runtime` = `-DincludeScope=runtime`（compile + runtime）
/// - `.compile` = `-DincludeScope=compile`（compile + provided + system）
/// 两者合并即 IDEA 的 "Include dependencies with 'Provided' scope"，且不含 test。
public enum MavenClasspathScope: String, Sendable, CaseIterable {
    case runtime
    case compile

    var includeScopeArgument: String { "-DincludeScope=\(rawValue)" }
}

/// §14: BuildSystemAdapter 协议。Gradle 实现在 Milestone 4。
public protocol BuildSystemAdapter {
    func compile(
        reactorModuleName: String?,
        hasModules: Bool,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws
    func resolveRuntimeClasspath(
        reactorModuleName: String?,
        hasModules: Bool,
        includeProvided: Bool,
        withCompile: Bool,
        runtimeOutputFile: URL,
        providedOutputFile: URL,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws -> [String]
}

/// §15/§17/§18: Maven 适配器。
/// - Maven 由 `MavenLocator` 按绝对路径候选定位（不依赖 shell PATH）
/// - compile 不 clean（增量）
/// - classpath 交给 Maven 自己解析（dependency:build-classpath），不重写依赖解析
/// - handle 非空时：构建进程句柄交给调用方，Stop 可终止构建（对齐 IDEA）
/// - `buildProject(kind:)` 是 IDEA 的 Build / Rebuild Project 与 Maven clean（整个 reactor）
public struct MavenBuildService: BuildSystemAdapter, Sendable {
    public let projectRoot: URL
    public let mavenExecutable: URL
    public let environment: [String: String]
    /// 默认 -nsu：跳过 SNAPSHOT 远程更新检查，优先用 ~/.m2 已有依赖（IDEA 下载过的即命中）。
    /// 与 IDEA 点 Run 的行为一致；本地缺失的依赖仍会正常首次下载。
    public let noSnapshotUpdates: Bool

    public init(
        projectRoot: URL,
        mavenExecutable: URL,
        environment: [String: String],
        noSnapshotUpdates: Bool = true
    ) {
        self.projectRoot = projectRoot
        self.mavenExecutable = mavenExecutable
        self.environment = environment
        self.noSnapshotUpdates = noSnapshotUpdates
    }

    /// §15: 定位 Maven。见 `MavenLocator`：不能只查 PATH，GUI 从 Dock 启动时 PATH 不含用户安装的 Maven。
    public static func discoverMavenExecutable(projectRoot: URL) -> URL? {
        MavenLocator.discover(projectRoot: projectRoot)?.executable
    }

    /// 构建/解析共用的 Maven 环境：JAVA_HOME 指向解析出的 JDK。
    public static func buildEnvironment(javaHome: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let javaHome {
            env["JAVA_HOME"] = javaHome.path
        }
        return env
    }

    /// §3.3: Make / Build = 只编译当前模块及其 reactor 依赖（`-pl <module> -am`）。
    public func compile(
        reactorModuleName: String?,
        hasModules: Bool,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        let arguments = Self.compileArguments(
            mavenExecutable: mavenExecutable,
            noSnapshotUpdates: noSnapshotUpdates,
            reactorModuleName: reactorModuleName,
            hasModules: hasModules
        )
        let status = try run(arguments: arguments, handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(detail: "Maven compile 失败（退出码 \(status)），详见控制台输出。")
        }
    }

    static func compileArguments(
        mavenExecutable: URL,
        noSnapshotUpdates: Bool,
        reactorModuleName: String?,
        hasModules: Bool
    ) -> [String] {
        styled(
            moduleFlags(reactorModuleName: reactorModuleName, hasModules: hasModules) + ["compile"],
            executable: mavenExecutable,
            noSnapshotUpdates: noSnapshotUpdates
        )
    }

    static func classpathArguments(
        mavenExecutable: URL,
        noSnapshotUpdates: Bool,
        scope: MavenClasspathScope,
        lifecyclePhase: String?,
        reactorModuleName: String?,
        hasModules: Bool,
        outputFile: URL
    ) -> [String] {
        var goals: [String] = []
        // §3.1: compile 只在同一次调用里出现一次。多模块的兄弟依赖（未 install 的
        // SNAPSHOT）只有当该模块在本次会话里跑过 ≥compile 阶段时才被 Maven 认作
        // 已解析（ReactorReader 会把 target/classes 标记成 artifact 文件）；
        // 单跑 dependency:build-classpath 会直接报 "Could not resolve dependencies"。
        // 所以需要 Build 时合并成一次调用，而不是先 compile 再解析。
        if let lifecyclePhase { goals.append(lifecyclePhase) }
        goals += ["dependency:build-classpath", scope.includeScopeArgument, "-Dmdep.outputFile=\(outputFile.path)"]
        return styled(
            moduleFlags(reactorModuleName: reactorModuleName, hasModules: hasModules) + goals,
            executable: mavenExecutable,
            noSnapshotUpdates: noSnapshotUpdates
        )
    }

    /// IDEA 的 Build Project / Rebuild Project 与 Maven clean：作用于整个 reactor，不带 `-pl`。
    /// Build = 增量 `compile`；Rebuild = `clean compile`（先清空产物再全量编译）；
    /// Clean = 只 `clean`（清空产物，不编译）。
    public func buildProject(kind: ProjectBuildKind, handle: ProcessHandle?, log: @escaping LogCallback) throws {
        let status = try run(
            arguments: Self.projectBuildArguments(
                mavenExecutable: mavenExecutable,
                noSnapshotUpdates: noSnapshotUpdates,
                kind: kind
            ),
            handle: handle,
            log: log
        )
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(
                detail: "Maven \(kind.goalsDescription) 失败（退出码 \(status)），详见\(kind.actionName)输出。"
            )
        }
    }

    static func projectBuildArguments(
        mavenExecutable: URL,
        noSnapshotUpdates: Bool,
        kind: ProjectBuildKind
    ) -> [String] {
        styled(kind.goalArguments, executable: mavenExecutable, noSnapshotUpdates: noSnapshotUpdates)
    }

    /// §3.1: classpath 解析本身不产生编译。
    /// `withCompile` 由调用方（`JavaLauncher`）依据配置里是否真的有 Build 任务决定：
    /// 有则把 compile 合进同一次调用（一次编译 + 一次解析，见 classpathArguments 的说明），
    /// 没有则一次都不编译——"Do not build before run" 必须真的不 Build（§11/§3.3）。
    /// §6.2: `includeProvided` = IDEA 的 "Include dependencies with 'Provided' scope"，
    /// 用 Maven 自己的 dependency plugin 分别取 runtime 与 compile 两段再合并，
    /// 不重写依赖解析（§5），也不会把 test scope 带进来。
    public func resolveRuntimeClasspath(
        reactorModuleName: String?,
        hasModules: Bool,
        includeProvided: Bool,
        withCompile: Bool,
        runtimeOutputFile: URL,
        providedOutputFile: URL,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws -> [String] {
        let phase = withCompile ? "compile" : nil
        var entries = try resolveClasspath(
            scope: .runtime,
            lifecyclePhase: phase,
            reactorModuleName: reactorModuleName,
            hasModules: hasModules,
            handle: handle,
            outputFile: runtimeOutputFile,
            log: log
        )
        guard includeProvided else { return entries }

        log(LogLine(stream: .system, text: "[IdeaLightRun] 合并 provided 依赖（-DincludeScope=compile）…"))
        entries += try resolveClasspath(
            scope: .compile,
            // 每次解析都是独立的 Maven 进程，reactor 标记不跨进程保留，
            // 第二段同样带上 compile 才能解析到未 install 的兄弟模块。
            lifecyclePhase: phase,
            reactorModuleName: reactorModuleName,
            hasModules: hasModules,
            handle: handle,
            outputFile: providedOutputFile,
            log: log
        )
        return entries
    }

    /// 单个 scope 的 `dependency:build-classpath`。
    public func resolveClasspath(
        scope: MavenClasspathScope,
        lifecyclePhase: String? = nil,
        reactorModuleName: String?,
        hasModules: Bool,
        handle: ProcessHandle?,
        outputFile: URL,
        log: @escaping LogCallback
    ) throws -> [String] {
        try FileManager.default.createDirectory(
            at: outputFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputFile)

        let arguments = Self.classpathArguments(
            mavenExecutable: mavenExecutable,
            noSnapshotUpdates: noSnapshotUpdates,
            scope: scope,
            lifecyclePhase: lifecyclePhase,
            reactorModuleName: reactorModuleName,
            hasModules: hasModules,
            outputFile: outputFile
        )
        let status = try run(arguments: arguments, handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.classpathResolveFailed(
                detail: "Maven dependency:build-classpath（\(scope.rawValue)）失败（退出码 \(status)），详见控制台输出。"
            )
        }
        guard let content = try? String(contentsOf: outputFile, encoding: .utf8) else {
            throw IdeaLightRunError.classpathResolveFailed(
                detail: "Maven 未生成 classpath 输出文件：\(outputFile.path)"
            )
        }
        // 无外部依赖时 Maven 输出空文件，classpath 仅剩 target/classes，属正常情况。
        return Self.splitClasspath(content)
    }

    /// Maven 用平台路径分隔符连接依赖；macOS/Linux 为 ":"，条目自身不会含 ":"。
    static func splitClasspath(_ content: String) -> [String] {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// §3.5: 执行 IDEA 保存的 Maven goal（如 `clean package`）。
    /// goal 原文按参数逐项传递，绝不转成 Java 命令（§2）。
    public func runGoals(
        _ goals: [String],
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        let status = try run(arguments: mavenArguments(base: goals), handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(
                detail: "Maven \(goals.joined(separator: " ")) 失败（退出码 \(status)），详见控制台输出。"
            )
        }
    }

    // MARK: - 内部

    /// §17: 多模块用 `-pl <module> -am` 限定范围，不 clean（增量）。
    static func moduleFlags(reactorModuleName: String?, hasModules: Bool) -> [String] {
        var arguments = ["-DskipTests"]
        if let name = reactorModuleName, hasModules {
            arguments += ["-pl", name, "-am"]
        }
        return arguments
    }

    private func mavenArguments(base: [String]) -> [String] {
        Self.styled(base, executable: mavenExecutable, noSnapshotUpdates: noSnapshotUpdates)
    }

    /// mvnw 自带进度输出，系统 mvn 加 -B 减少噪音；-nsu 跳过 SNAPSHOT 远程更新检查。
    private static func styled(
        _ arguments: [String],
        executable: URL,
        noSnapshotUpdates: Bool
    ) -> [String] {
        var result = arguments
        if noSnapshotUpdates {
            result.insert("-nsu", at: 0)
        }
        if executable.lastPathComponent != "mvnw" {
            result.insert("-B", at: 0)
        }
        return result
    }

    /// 同步执行 Maven，stdout/stderr 由读线程逐行回调（可能来自后台线程）。
    /// handle.terminate() 可终止构建（§：构建期可停止，对齐 IDEA）。
    func run(arguments: [String], handle: ProcessHandle?, log: @escaping LogCallback) throws -> Int32 {
        let process = Process()
        process.executableURL = mavenExecutable
        process.arguments = arguments
        process.currentDirectoryURL = projectRoot
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = Pipe()

        let ioLock = NSLock()
        var splitters: [LogStream: LineSplitter] = [:]
        let readerGroup = DispatchGroup()
        let clock = { Date() }

        func ingest(_ data: Data, stream: LogStream) {
            var lines: [String] = []
            ioLock.lock()
            var splitter = splitters[stream] ?? LineSplitter()
            lines = splitter.feed(data)
            splitters[stream] = splitter
            ioLock.unlock()
            for line in lines {
                log(LogLine(timestamp: clock(), stream: stream, text: line))
            }
        }

        func pump(_ stream: LogStream, fileHandle: FileHandle) {
            readerGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readerGroup.leave() }
                while true {
                    let data = fileHandle.readData(ofLength: 65536)
                    if data.isEmpty { return }  // EOF
                    ingest(data, stream: stream)
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw IdeaLightRunError.buildToolNotFound(detail: "无法执行 \(mavenExecutable.path)：\(error.localizedDescription)")
        }
        handle?.attach(process)

        pump(.stdout, fileHandle: stdoutPipe.fileHandleForReading)
        pump(.stderr, fileHandle: stderrPipe.fileHandleForReading)

        semaphoreWait(process: process)
        handle?.detach()
        readerGroup.wait()

        // 冲刷最后的半行
        ioLock.lock()
        let leftovers = splitters
        splitters = [:]
        ioLock.unlock()
        for (stream, splitter) in leftovers {
            var splitter = splitter
            if let last = splitter.finish(), !last.isEmpty {
                log(LogLine(timestamp: clock(), stream: stream, text: last))
            }
        }

        // §：构建被 Stop 终止时，不要报"构建失败"而是"已停止"
        if handle?.isCancelled == true {
            throw IdeaLightRunError.launchCancelled(detail: "构建已被用户停止。")
        }
        return process.terminationStatus
    }

    private func semaphoreWait(process: Process) {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        semaphore.wait()
    }
}
