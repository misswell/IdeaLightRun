import Foundation

/// 项目目录的轻量 git 操作：读当前分支、列本地分支、切换分支、拉取远端更新。
/// §27: 一律 `Process.arguments` 数组传参，绝不经 shell。
/// 联网说明（§64）：平时只读本地 `.git`；只有用户主动点「切换分支 / 拉取」时
/// git 才会访问远端——与「检查更新…」同属用户显式发起的网络动作。
public struct GitClient: Sendable {
    public let gitPath: String

    public init(gitPath: String? = nil) {
        self.gitPath = gitPath ?? Self.locateGit() ?? "/usr/bin/git"
    }

    /// GUI 从 Dock 启动时拿不到完整 PATH（同 MavenLocator 的问题），按绝对路径枚举。
    static let candidateGitPaths = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/opt/local/bin/git",
    ]

    public static func locateGit() -> String? {
        candidateGitPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct RunResult: Equatable, Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { exitCode == 0 }
    }

    // MARK: 只读查询

    /// 目录是否为 git 工作区。空的仓库（还没有提交）也算。
    public func isRepository(at projectURL: URL) -> Bool {
        let result = run(["rev-parse", "--is-inside-work-tree"], at: projectURL)
        return result.succeeded && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// 当前分支；仓库还没有提交、或处于分离 HEAD 时返回 nil。
    public func currentBranch(at projectURL: URL) -> String? {
        let result = run(["rev-parse", "--abbrev-ref", "HEAD"], at: projectURL)
        guard result.succeeded else { return nil }
        return Self.parseCurrentBranch(result.stdout)
    }

    /// 本地分支列表（git 默认按 refname 升序）。
    public func branches(at projectURL: URL) -> [String] {
        let result = run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], at: projectURL)
        guard result.succeeded else { return [] }
        return Self.parseBranchList(result.stdout)
    }

    // MARK: 变更操作

    /// 切换到指定本地分支。工作区有未提交修改而 git 拒绝时，由调用方原样展示 stderr。
    @discardableResult
    public func checkout(_ branch: String, at projectURL: URL) -> RunResult {
        run(["checkout", branch], at: projectURL)
    }

    /// `git pull --ff-only`：只接受快进。本地与远端分叉时直接失败并把原因交给
    /// 用户，绝不自作主张生成 merge commit。
    @discardableResult
    public func pull(at projectURL: URL) -> RunResult {
        run(["pull", "--ff-only"], at: projectURL)
    }

    // MARK: 执行

    public func run(_ arguments: [String], at projectURL: URL, timeout: TimeInterval = 120) -> RunResult {
        Self.run(executable: gitPath, arguments: arguments, directory: projectURL, timeout: timeout)
    }

    /// 无终端的 GUI 进程里，git 若要交互式输入凭据会永远挂着：禁掉终端提示
    /// （钥匙串 helper 等非交互凭据源不受影响），再配超时兜底，超时即 SIGTERM。
    public static func run(executable: String, arguments: [String], directory: URL, timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1, stdout: "", stderr: String(describing: error))
        }

        var stdout = Data()
        var stderr = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global().async {
            stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            readGroup.wait()
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 10)
        }

        return RunResult(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    }

    // MARK: 解析（可单测）

    /// `rev-parse --abbrev-ref HEAD` 的输出：空串或 "HEAD"（分离 HEAD）都算没有分支。
    static func parseCurrentBranch(_ output: String) -> String? {
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    /// `for-each-ref --format=%(refname:short)` 的输出：每行一个分支名，去重保序。
    static func parseBranchList(_ output: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// 第一行非空文本：成功提示与失败原因（stderr 首行）都用它。
    public static func firstMeaningfulLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
