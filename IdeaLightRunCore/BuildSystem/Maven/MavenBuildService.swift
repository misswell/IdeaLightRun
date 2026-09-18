import Foundation

/// §14: BuildSystemAdapter 协议。Gradle 实现在 Milestone 4。
public protocol BuildSystemAdapter {
    func compile(reactorModuleName: String?, hasModules: Bool, log: @escaping LogCallback) throws
    func resolveRuntimeClasspath(
        reactorModuleName: String?,
        hasModules: Bool,
        outputFile: URL,
        log: @escaping LogCallback
    ) throws -> [String]
}

/// §15/§17/§18: Maven 适配器。
/// - mvnw 优先，其次 PATH 中的 mvn
/// - compile 不 clean（增量）
/// - classpath 交给 Maven 自己解析（dependency:build-classpath），不重写依赖解析
public struct MavenBuildService: BuildSystemAdapter {
    public let projectRoot: URL
    public let mavenExecutable: URL
    public let environment: [String: String]

    public init(projectRoot: URL, mavenExecutable: URL, environment: [String: String]) {
        self.projectRoot = projectRoot
        self.mavenExecutable = mavenExecutable
        self.environment = environment
    }

    /// §15: 项目自带 Wrapper 优先，其次 PATH 中的 mvn。
    public static func discoverMavenExecutable(projectRoot: URL) -> URL? {
        let wrapper = projectRoot.appendingPathComponent("mvnw")
        if FileManager.default.isExecutableFile(atPath: wrapper.path) {
            return wrapper
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("mvn")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// 构建/解析共用的 Maven 环境：JAVA_HOME 指向解析出的 JDK。
    public static func buildEnvironment(javaHome: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let javaHome {
            env["JAVA_HOME"] = javaHome.path
        }
        return env
    }

    public func compile(reactorModuleName: String?, hasModules: Bool, log: @escaping LogCallback) throws {
        let status = try run(arguments: mavenArguments(base: baseModuleArguments(reactorModuleName: reactorModuleName, hasModules: hasModules) + ["compile"]), log: log)
        guard status == 0 else {
            throw IdeaLightRunError.buildFailed(detail: "Maven compile 失败（退出码 \(status)），详见控制台输出。")
        }
    }

    /// §18: compile + dependency:build-classpath 一次 JVM 调用完成（Cold Resolve）。
    public func resolveRuntimeClasspath(
        reactorModuleName: String?,
        hasModules: Bool,
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
        let status = try run(arguments: mavenArguments(base: arguments), log: log)
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
        guard !entries.isEmpty else {
            throw IdeaLightRunError.classpathResolveFailed(detail: "Maven 输出的 classpath 为空。")
        }
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
        if mavenExecutable.lastPathComponent == "mvnw" {
            return base
        }
        // 系统 mvn：加 batch 模式减少噪音
        return ["-B"] + base
    }

    /// 同步执行 Maven，stdout/stderr 逐行回调（可能来自后台线程）。
    func run(arguments: [String], log: @escaping LogCallback) throws -> Int32 {
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
        let now = { Date() }

        func makeHandler(_ stream: LogStream, _ pipe: Pipe) -> (FileHandle) -> Void {
            { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                ioLock.lock()
                var splitter = splitters[stream] ?? LineSplitter()
                let lines = splitter.feed(data)
                splitters[stream] = splitter
                ioLock.unlock()
                for line in lines {
                    log(LogLine(timestamp: now(), stream: stream, text: line))
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = makeHandler(.stdout, stdoutPipe)
        stderrPipe.fileHandleForReading.readabilityHandler = makeHandler(.stderr, stderrPipe)

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw IdeaLightRunError.buildToolNotFound(detail: "无法执行 \(mavenExecutable.path)：\(error.localizedDescription)")
        }
        semaphore.wait()

        // 进程已退出：移除 handler 后读取管道残余，冲刷最后的半行
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let leftoverStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let leftoverStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        ioLock.lock()
        for (stream, leftover) in [(LogStream.stdout, leftoverStdout), (LogStream.stderr, leftoverStderr)] {
            guard !leftover.isEmpty else { continue }
            var splitter = splitters[stream] ?? LineSplitter()
            for line in splitter.feed(leftover) {
                log(LogLine(timestamp: now(), stream: stream, text: line))
            }
            if let last = splitter.finish(), !last.isEmpty {
                log(LogLine(timestamp: now(), stream: stream, text: last))
            }
            splitters[stream] = splitter
        }
        ioLock.unlock()
        return process.terminationStatus
    }
}
