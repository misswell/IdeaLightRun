import Foundation

/// §32/§33/§36/§37: 单个 Java 进程会话。
/// - Process.arguments 数组传参，绝不走 /bin/sh -c（§27）
/// - stdout/stderr 分别 Pipe 捕获进入环形缓冲（§36/§37）
/// - 100ms 批量回调（§103）
/// - stop(): SIGTERM → 3 秒后仍存活则保持 .stopping，由用户决定 Force Kill（§33）
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
    private var forceKilled = false
    private var timerResumed = false

    private let process: Process
    private let flushTimer: DispatchSourceTimer
    private let flushQueue = DispatchQueue(label: "com.misswell.IdeaLightRun.log-flush", qos: .utility)

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
        // §27: 参数逐项传递
        process.arguments = plan.vmArguments
            + ["-cp", plan.classpath.joined(separator: ":"), plan.mainClass]
            + plan.programArguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardInput = Pipe()
        self.process = process

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        flushTimer = DispatchSource.makeTimerSource(queue: flushQueue)
        flushTimer.schedule(deadline: .now() + 0.1, repeating: 0.1)

        // self 至此已完成初始化，以下闭包才能捕获 self
        flushTimer.setEventHandler { [weak self] in
            self?.flushNow()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.ingest(data, stream: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.ingest(data, stream: .stderr)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            // 冲刷管道中的残余输出
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let leftoverStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let leftoverStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !leftoverStdout.isEmpty { self.ingest(leftoverStdout, stream: .stdout) }
            if !leftoverStderr.isEmpty { self.ingest(leftoverStderr, stream: .stderr) }

            self.lock.lock()
            self.stateValue = .exited(terminatedProcess.terminationStatus)
            self.lock.unlock()
            self.flushNow()
            self.onState?(.exited(terminatedProcess.terminationStatus))
        }
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
        do {
            try process.run()
        } catch {
            let message = "启动失败：\(error.localizedDescription)"
            logBuffer.append(LogLine(stream: .system, text: "[IdeaLightRun] \(message)"))
            setState(.failed(message))
            return
        }
        lock.lock()
        let firstStart = !timerResumed
        timerResumed = true
        lock.unlock()
        if firstStart {
            flushTimer.resume()
        }
        logBuffer.append(LogLine(stream: .system, text: "[IdeaLightRun] 进程已启动，PID \(process.processIdentifier)"))
        setState(.running)
    }

    /// §33: 先 SIGTERM；3 秒后仍存活则保持 .stopping，等待用户 Force Kill。
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
        lock.lock()
        forceKilled = true
        lock.unlock()
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
