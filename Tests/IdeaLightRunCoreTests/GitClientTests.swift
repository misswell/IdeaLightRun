import XCTest
@testable import IdeaLightRunCore

/// GitClient 的解析与真实 git 集成：全部本地操作（clone/pull 走本地路径），
/// 不访问网络。git 不可用（理论上 macOS 自带 /usr/bin/git）时跳过集成用例。
final class GitClientTests: XCTestCase {
    private var scratch: URL!
    private var client: GitClient!

    override func setUpWithError() throws {
        guard GitClient.locateGit() != nil else {
            throw XCTSkip("系统未安装 git，跳过 GitClient 集成测试")
        }
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        client = GitClient()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: 解析

    func testParseCurrentBranchTrimsAndRejectsDetachedHead() {
        XCTAssertEqual(GitClient.parseCurrentBranch("main\n"), "main")
        XCTAssertEqual(GitClient.parseCurrentBranch("  feature/x \n"), "feature/x")
        XCTAssertNil(GitClient.parseCurrentBranch(""))
        XCTAssertNil(GitClient.parseCurrentBranch("HEAD\n"))
    }

    func testParseBranchListDedupesAndKeepsOrder() {
        let output = """
        main
        feature/a

        feature/b
        main
        """
        XCTAssertEqual(GitClient.parseBranchList(output), ["main", "feature/a", "feature/b"])
        XCTAssertEqual(GitClient.parseBranchList(""), [])
    }

    // MARK: 真实 git（本地仓库，无网络）

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitClient.locateGit()!)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // CI 与本机的 git 身份都可能没配，提交时内联指定
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) 失败")
    }

    private func write(_ relativePath: String, in directory: URL, content: String) throws {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testBranchReadAndCheckoutOnLocalRepository() throws {
        let repo = scratch.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertFalse(client.isRepository(at: scratch), "非仓库目录不算 git 工作区")
        XCTAssertFalse(client.isRepository(at: repo), "还没有 .git 的目录不是仓库")

        try git(["init"], in: repo)
        XCTAssertTrue(client.isRepository(at: repo), "init 后是仓库，即使还没有提交")
        try write("a.txt", in: repo, content: "1")
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "init"], in: repo)

        let initial = try XCTUnwrap(client.currentBranch(at: repo))
        XCTAssertNotEqual(initial, "HEAD")

        try git(["checkout", "-b", "feature/x"], in: repo)
        XCTAssertEqual(client.currentBranch(at: repo), "feature/x")
        let branches = client.branches(at: repo)
        XCTAssertTrue(branches.contains(initial))
        XCTAssertTrue(branches.contains("feature/x"))

        // 切回原分支
        let result = client.checkout(initial, at: repo)
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertEqual(client.currentBranch(at: repo), initial)
    }

    func testPullFastForwardSucceedsAndDivergenceFails() throws {
        // 上游仓库（普通工作区即可；fetch/pull 不要求 bare）
        let origin = scratch.appendingPathComponent("origin", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try git(["init"], in: origin)
        try write("a.txt", in: origin, content: "1")
        try git(["add", "."], in: origin)
        try git(["commit", "-m", "init"], in: origin)

        let clone = scratch.appendingPathComponent("clone", isDirectory: true)
        try git(["clone", origin.path, clone.path], in: scratch)
        XCTAssertEqual(client.currentBranch(at: clone), client.currentBranch(at: origin))

        // 无新提交时 pull 成功（"Already up to date."）
        let upToDate = client.pull(at: clone)
        XCTAssertTrue(upToDate.succeeded, upToDate.stderr)

        // 上游前进一个提交 → 快进拉取成功
        try write("a.txt", in: origin, content: "2")
        try git(["add", "."], in: origin)
        try git(["commit", "-m", "second"], in: origin)
        let ff = client.pull(at: clone)
        XCTAssertTrue(ff.succeeded, ff.stderr)
        let pulled = try String(contentsOf: clone.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(pulled, "2")

        // 双方各前进一个提交 → --ff-only 拒绝，绝不自动 merge
        try write("local.txt", in: clone, content: "local")
        try git(["add", "."], in: clone)
        try git(["commit", "-m", "local work"], in: clone)
        try write("a.txt", in: origin, content: "3")
        try git(["add", "."], in: origin)
        try git(["commit", "-m", "third"], in: origin)
        let diverged = client.pull(at: clone)
        XCTAssertFalse(diverged.succeeded, "分叉时 --ff-only 必须失败而不是生成 merge commit")
        XCTAssertFalse(GitClient.firstMeaningfulLine(diverged.stderr).isNilOrEmpty)
        // 本地提交完好无损
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent("local.txt").path))
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self == nil || self!.isEmpty }
}
