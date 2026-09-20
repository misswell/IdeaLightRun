import Foundation

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
        handle: ProcessHandle?,
        outputFile: URL,
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

    public func compile(
        reactorModuleName: String?,
        hasModules: Bool,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        let arguments = mavenArguments(
            base: baseModuleArguments(reactorModuleName: reactorModuleName, hasModules: hasModules) + ["compile"]
        )
        let status = try run(arguments: arguments, handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(detail: "Maven compile 失败（退出码 \(status)），详见控制台输出。")
        }
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

    /// §18: compile + dependency:build-classpath 一次 JVM 调用完成（Cold Resolve）。
    public func resolveRuntimeClasspath(
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

        var arguments = baseModuleArguments(reactorModuleName: reactorModuleName, hasModules: hasModules)
        arguments += [
            "compile",
            "dependency:build-classpath",
            "-DincludeScope=runtime",
            "-Dmdep.outputFile=\(outputFile.path)",
        ]
        let status = try run(arguments: mavenArguments(base: arguments), handle: handle, log: log)
        guard status == 0 else {
            throw IdeaLightRunError.classpathResolveFailed(detail: "Maven dependency:build-classpath 失败（退出码 \(status)），详见控制台输出。")
        }
        guard let content = try? String(contentsOf: outputFile, encoding: .utf8) else {
            throw IdeaLightRunError.classpathResolveFailed(detail: "Maven 未生成 classpath 输出文件：\(outputFile.path)")
        }
        let entries = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        // 无外部依赖时 Maven 输出空文件，classpath 仅剩 target/classes，属正常情况。
        return entries
    }

    // MARK: - 内部

    private func baseModuleArguments(reactorModuleName: String?, hasModules: Bool) -> [String] {
        var arguments = ["-DskipTests"]
        // §17: 多模块用 -pl <module> -am，不 clean
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
