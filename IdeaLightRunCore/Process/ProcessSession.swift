import Foundation

/// §32/§33/§36/§37: 单个 Java 进程会话。
/// - Process.arguments 数组传参，绝不走 /bin/sh -c（§27）
/// - stdout/stderr 分别由读线程捕获进入环形缓冲（§36/§37）
///   （读线程而非 readabilityHandler：避免与 readDataToEndOfFile 混用的 Foundation 竞态崩溃）
/// - 100ms 批量回调（§103）
/// - stop(): SIGTERM → 由用户决定 Force Kill（§33）
public final class ProcessSession {
    public let configKey: String
    public let configName: String
    public let logBuffer: LogRingBuffer

    /// 回调可能来自后台线程，调用方负责线程切换。
    public var onState: ((ProcessState) -> Void)?
    public var onLogLines: (([LogLine]) -> Void)?

    private let lock = NSLock()
    private var stateValue: ProcessState = .starting
    private var splitters: [LogStream: LineSplitter] = [:]
    private var exitStatusValue: Int32?

    private let process: Process
    private let flushTimer: DispatchSourceTimer
    private let flushQueue = DispatchQueue(label: "com.misswell.IdeaLightRun.log-flush", qos: .utility)
    private let readerGroup = DispatchGroup()

    public init(
        configKey: String,
        configName: String,
        plan: JavaLaunchPlan,
        logBuffer: LogRingBuffer = LogRingBuffer()
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: plan.javaExecutable.path) else {
            throw IdeaLightRunError.jdkNotFound(detail: "Java 可执行文件不存在或不可执行：\(plan.javaExecutable.path)")
        }
        self.configKey = configKey
        self.configName = configName
        self.logBuffer = logBuffer

        let process = Process()
        process.executableURL = plan.javaExecutable
        // §27: 参数逐项传递。mainClass 为空视为非 Java 启动（测试/工具进程）。
        if plan.mainClass.isEmpty {
            process.arguments = plan.vmArguments + plan.programArguments
        } else {
            process.arguments = plan.vmArguments
                + ["-cp", plan.classpath.joined(separator: ":"), plan.mainClass]
                + plan.programArguments
        }
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardInput = Pipe()
        self.process = process

        // 定时器在 init 就 resume：deinit 只能 cancel 已恢复的 source，
        // 否则 start() 失败/未调用时释放挂起的 source 会直接崩溃。
        flushTimer = DispatchSource.makeTimerSource(queue: flushQueue)
        flushTimer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        flushTimer.setEventHandler { [weak self] in
            self?.flushNow()
        }
        flushTimer.resume()
    }

    deinit {
        flushTimer.cancel()
    }

    public var state: ProcessState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    public var pid: Int32 {
        process.processIdentifier
    }

    public var isRunning: Bool {
        state == .running || state == .stopping
    }

    public func start() {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            let message = "启动失败：\(error.localizedDescription)"
            logBuffer.append(LogLine(stream: .system, text: "[IdeaLightRun] \(message)"))
            setState(.failed(message))
            return
        }

        logBuffer.append(LogLine(stream: .system, text: "[IdeaLightRun] 进程已启动，PID \(process.processIdentifier)"))
        setState(.running)

        // 读线程持续消费管道直到 EOF；EOF + 退出码齐备后统一收尾
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.lock.lock()
            self.exitStatusValue = terminatedProcess.terminationStatus
            self.lock.unlock()
        }
        readerGroup.notify(queue: flushQueue) { [weak self] in
            self?.finishReading()
        }
        pump(.stdout, fileHandle: stdoutPipe.fileHandleForReading)
        pump(.stderr, fileHandle: stderrPipe.fileHandleForReading)
    }

    /// §33: 先 SIGTERM；仍存活则保持 .stopping，等待用户 Force Kill。
    public func stop() {
        lock.lock()
        guard stateValue == .running else {
            lock.unlock()
            return
        }
        stateValue = .stopping
        lock.unlock()
        onState?(.stopping)
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
    }

    public func forceKill() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    /// 用于 Restart 前等待旧进程退出（§34）。
    public func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning
    }

    public func appendSystemLog(_ text: String) {
        logBuffer.append(LogLine(stream: .system, text: "[IdeaLightRun] \(text)"))
    }

    // MARK: - 内部

    private func pump(_ stream: LogStream, fileHandle: FileHandle) {
        readerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.readerGroup.leave() }
            while true {
                let data = fileHandle.readData(ofLength: 65536)
                if data.isEmpty { return }  // EOF
                self?.ingest(data, stream: stream)
            }
        }
    }

    private func finishReading() {
        // 尾部半行
        lock.lock()
        let remainingSplitters = splitters
        splitters = [:]
        var status = exitStatusValue
        lock.unlock()
        for (stream, splitter) in remainingSplitters {
            var splitter = splitter
            if let last = splitter.finish(), !last.isEmpty {
                logBuffer.append(LogLine(stream: stream, text: last))
            }
        }

        // terminationHandler 与 EOF 顺序不定，短暂等待退出码
        var waitedMilliseconds = 0
        while status == nil && waitedMilliseconds < 2000 {
            Thread.sleep(forTimeInterval: 0.02)
            waitedMilliseconds += 20
            lock.lock()
            status = exitStatusValue
            lock.unlock()
        }

        let exitCode = status ?? 0
        lock.lock()
        stateValue = .exited(exitCode)
        lock.unlock()
        flushNow()
        onState?(.exited(exitCode))
    }

    private func ingest(_ data: Data, stream: LogStream) {
        var newLines: [LogLine] = []
        lock.lock()
        var splitter = splitters[stream] ?? LineSplitter()
        for line in splitter.feed(data) {
            newLines.append(LogLine(stream: stream, text: line))
        }
        splitters[stream] = splitter
        lock.unlock()
        if !newLines.isEmpty {
            logBuffer.append(newLines)
        }
    }

    private func flushNow() {
        let batch = logBuffer.drainPending()
        guard !batch.isEmpty else { return }
        onLogLines?(batch)
    }

    private func setState(_ newState: ProcessState) {
        lock.lock()
        stateValue = newState
        lock.unlock()
        onState?(newState)
    }
}
