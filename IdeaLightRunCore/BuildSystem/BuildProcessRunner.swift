import Foundation

/// Maven / Gradle 共用的构建进程执行：stdout/stderr 逐行回调、句柄可终止、
/// 停止后报“已停止”而不是“构建失败”。
///
/// 参数一律走 `Process.arguments` 数组（§27），调用方只给可执行文件与参数列表。
enum BuildProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
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
                    // availableData 而非 readData(ofLength:)：后者要凑满 64KB 或 EOF 才返回，
                    // 编译日志会成段攒住（和运行期日志一样的症状）。
                    let data = fileHandle.availableData
                    if data.isEmpty { return }  // EOF
                    ingest(data, stream: stream)
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw IdeaLightRunError.buildToolNotFound(detail: "无法执行 \(executable.path)：\(error.localizedDescription)")
        }
        handle?.attach(process)

        pump(.stdout, fileHandle: stdoutPipe.fileHandleForReading)
        pump(.stderr, fileHandle: stderrPipe.fileHandleForReading)

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        semaphore.wait()
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

        // 构建被 Stop 终止时，不要报“构建失败”而是“已停止”
        if handle?.isCancelled == true {
            throw IdeaLightRunError.launchCancelled(detail: "构建已被用户停止。")
        }
        return process.terminationStatus
    }
}
