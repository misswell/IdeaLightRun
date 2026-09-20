import Foundation

/// §32/§33/§36/§37: 单个 Java 进程会话。
/// - Process.arguments 数组传参，绝不走 /bin/sh -c（§27）
/// - stdout/stderr 分别由读线程捕获进入环形缓冲（§36/§37）
///   （读线程而非 readabilityHandler：避免与 readDataToEndOfFile 混用的 Foundation 竞态崩溃）
/// - 退出以进程本身为准：管道 EOF 只代表"暂时没有输出"，不代表进程退出
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
    private var hasTerminated = false
    /// 收尾只生效一次；只在 flushQueue 上读写，无需加锁。
    private var didFinish = false

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

        // 退出状态以进程本身为准；管道只决定日志何时读完。
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.lock.lock()
            self.exitStatusValue = terminatedProcess.terminationStatus
            self.hasTerminated = true
            self.lock.unlock()
            // 被启动的进程可能派生子进程继承管道写端，使 EOF 迟迟不到；
            // 给读线程一个宽限期送完尾部日志，之后必须落定状态，否则永远停在"运行中"。
            self.flushQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.finishOnce()
            }
        }
        // 必须先 pump 再 notify：notify 在计数已归零时会立即投递，
        // 那样进程刚启动就被判成退出。
        pump(.stdout, fileHandle: stdoutPipe.fileHandleForReading)
        pump(.stderr, fileHandle: stderrPipe.fileHandleForReading)
        readerGroup.notify(queue: flushQueue) { [weak self] in
            self?.finishOnce()
        }
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
                guard let self else { return }
                let data = fileHandle.readData(ofLength: 65536)
                if data.isEmpty {
                    // 管道 EOF ≠ 进程退出：被启动的进程可以自行关闭/重定向 fd 1、2，
                    // 或读操作被瞬时错误打断。此时必须继续排空（否则对端写满 64KB 会永久阻塞），
                    // 只有进程真的退出才结束读取。
                    if self.processHasExited() { return }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                self.ingest(data, stream: stream)
            }
        }
    }

    /// terminationHandler 可能来不及回调（进程在赋值前就退出），因此同时向 Process 本身确认。
    private func processHasExited() -> Bool {
        lock.lock()
        if hasTerminated {
            lock.unlock()
            return true
        }
        lock.unlock()
        guard !process.isRunning else { return false }
        lock.lock()
        exitStatusValue = process.terminationStatus
        hasTerminated = true
        lock.unlock()
        return true
    }

    /// 收尾：读线程全部结束，或进程退出后过了宽限期。两条路径都可能到达，只生效一次。
    /// 只在 flushQueue 上执行，因此 didFinish 无需加锁。
    private func finishOnce() {
        guard !didFinish else { return }
        didFinish = true

        lock.lock()
        let remainingSplitters = splitters
        splitters = [:]
        let status = exitStatusValue
        lock.unlock()
        for (stream, splitter) in remainingSplitters {
            var splitter = splitter
            if let last = splitter.finish(), !last.isEmpty {
                logBuffer.append(LogLine(stream: stream, text: last))
            }
        }

        // 读线程只在进程确认退出后才收尾，退出码此时必定已知；
        // 拿不到就是状态机出了问题，绝不能报成"退出码 0"的成功假象。
        guard let exitCode = status else {
            flushNow()
            setState(.failed("进程状态未知：未取到退出码"))
            return
        }
        flushNow()
        setState(.exited(exitCode))
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
