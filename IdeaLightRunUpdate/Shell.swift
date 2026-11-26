import Darwin
import Foundation

enum Shell {
    struct Outcome: Sendable {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }

        /// 命令超过时限后被我们终止：调用方要把它当「命令失败」展示，
        /// 而不是把超时误报成签名不对。
        static let timedOutStatus: Int32 = -2
    }

    /// 更新流程里的外部命令都不该无限期挂着。给一个宽裕但确定的上限，
    /// 失败至少能落到面板上，不会永远停在「正在安装」。
    static let defaultTimeout: TimeInterval = 120

    /// 只负责把外部命令跑完并回收输出。退出码非 0 不抛错——调用方要按
    /// 具体命令决定它意味着「签名不对」还是「命令本身跑不了」。
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) throws -> Outcome {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        // 必须先开读、再等退出。反过来的话，子进程的输出写满 16 KB 管道后
        // 会卡在 write 上，而父进程在 waitUntilExit 里等它退出，两边永远互等。
        // macOS 27 的 `codesign --display --verbose=4` 实测就是这种卡法，
        // 更新面板会因此永远停在「正在安装」。
        let buffer = OutputBuffer()
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
            readerDone.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            _ = readerDone.wait(timeout: .now() + 1)
            return Outcome(
                status: -1,
                output: "无法启动 \(executable)：\(error.localizedDescription)"
            )
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }

        // 子进程退出后写端关闭，reader 读到 EOF。这里再加一个上限，
        // 避免异常情况下把后台线程永远留在那里。
        _ = readerDone.wait(timeout: .now() + 5)

        let output = String(decoding: buffer.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut {
            let detail = "命令 \(executable) 超过 \(Int(timeout)) 秒未结束，已终止。"
            return Outcome(
                status: Outcome.timedOutStatus,
                output: output.isEmpty ? detail : "\(detail)\n\(output)"
            )
        }
        return Outcome(status: process.terminationStatus, output: output)
    }

    @discardableResult
    static func runChecked(_ executable: String, _ arguments: [String], failure: UpdateError) throws -> String {
        let outcome = try run(executable, arguments)
        guard outcome.succeeded else {
            let couldNotRun = outcome.status == -1 || outcome.status == Outcome.timedOutStatus
            throw couldNotRun ? UpdateError.commandFailed(outcome.output) : failure
        }
        return outcome.output
    }
}

/// 读取线程与等待退出的线程并发访问；用锁而不是依赖「反正只会写一次」。
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
