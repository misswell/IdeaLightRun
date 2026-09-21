import Foundation

enum Shell {
    struct Outcome: Sendable {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    /// 只负责把外部命令跑完并回收输出。退出码非 0 不抛错——调用方要按
    /// 具体命令决定它意味着「签名不对」还是「命令本身跑不了」。
    static func run(_ executable: String, _ arguments: [String]) throws -> Outcome {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Outcome(
                status: -1,
                output: "无法启动 \(executable)：\(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Outcome(status: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func runChecked(_ executable: String, _ arguments: [String], failure: UpdateError) throws -> String {
        let outcome = try run(executable, arguments)
        guard outcome.succeeded else {
            throw outcome.status == -1 ? UpdateError.commandFailed(outcome.output) : failure
        }
        return outcome.output
    }
}
