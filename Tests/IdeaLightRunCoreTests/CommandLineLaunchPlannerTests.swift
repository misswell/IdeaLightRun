import XCTest
@testable import IdeaLightRunCore

/// 命令行模式不是 IDEA Run Configuration：它必须接受任意项目目录、
/// 把用户命令当作一个整体参数交给登录 zsh，并且复用统一的启动计划。
final class CommandLineLaunchPlannerTests: XCTestCase {
    private var projectRoot: URL!

    override func setUpWithError() throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-command-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let projectRoot {
            try? FileManager.default.removeItem(at: projectRoot)
        }
    }

    func testUsesLoginZshAndKeepsCommandAsOneArgument() throws {
        let plan = try CommandLineLaunchPlanner.plan(
            settings: CommandLineSettings(command: "npm run dev"),
            projectRoot: projectRoot,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(plan.executable.path, "/bin/zsh")
        XCTAssertEqual(plan.arguments, ["-ilc", "npm run dev"])
        XCTAssertEqual(plan.workingDirectory.path, projectRoot.standardizedFileURL.path)
        XCTAssertEqual(plan.displayCommand, "npm run dev")
        XCTAssertEqual(plan.environment["PATH"], "/usr/bin:/bin")
        XCTAssertTrue(plan.temporaryArtifacts.isEmpty)
        XCTAssertNil(plan.hotReload)
    }

    func testEmptyOrWhitespaceCommandIsRejected() {
        for command in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(
                try CommandLineLaunchPlanner.plan(
                    settings: CommandLineSettings(command: command),
                    projectRoot: projectRoot
                )
            ) { error in
                guard case IdeaLightRunError.invalidConfiguration(let detail) = error else {
                    return XCTFail("期望 invalidConfiguration，实际 \(error)")
                }
                XCTAssertTrue(detail.contains("命令"), detail)
            }
        }
    }

    func testRelativeWorkingDirectoryResolvesAgainstProjectRoot() throws {
        let plan = try CommandLineLaunchPlanner.plan(
            settings: CommandLineSettings(command: "pwd", workingDirectory: "sub"),
            projectRoot: projectRoot
        )
        XCTAssertEqual(
            plan.workingDirectory.path,
            projectRoot.appendingPathComponent("sub").standardizedFileURL.path
        )
    }

    func testProjectDirMacroAndTildeAreExpanded() throws {
        let macroPlan = try CommandLineLaunchPlanner.plan(
            settings: CommandLineSettings(command: "pwd", workingDirectory: "$PROJECT_DIR$/sub"),
            projectRoot: projectRoot
        )
        XCTAssertEqual(
            macroPlan.workingDirectory.path,
            projectRoot.appendingPathComponent("sub").standardizedFileURL.path
        )

        let homePlan = try CommandLineLaunchPlanner.plan(
            settings: CommandLineSettings(command: "pwd", workingDirectory: "~"),
            projectRoot: projectRoot
        )
        XCTAssertEqual(
            homePlan.workingDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        )
    }

    func testMissingWorkingDirectoryIsRejected() {
        XCTAssertThrowsError(
            try CommandLineLaunchPlanner.plan(
                settings: CommandLineSettings(command: "pwd", workingDirectory: "missing"),
                projectRoot: projectRoot
            )
        ) { error in
            guard case IdeaLightRunError.invalidConfiguration(let detail) = error else {
                return XCTFail("期望 invalidConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("missing"), detail)
            XCTAssertTrue(detail.contains("项目根"), detail)
        }
    }

    func testEnvironmentTextMergesAndOverridesParentEnvironment() throws {
        let plan = try CommandLineLaunchPlanner.plan(
            settings: CommandLineSettings(
                command: "env",
                environmentText: """
                BASE=override
                EXTRA="hello world"
                # comment
                export THIRD=${BASE}-suffix
                """
            ),
            projectRoot: projectRoot,
            environment: ["PATH": "/usr/bin", "BASE": "parent"]
        )

        XCTAssertEqual(plan.environment["PATH"], "/usr/bin")
        XCTAssertEqual(plan.environment["BASE"], "override")
        XCTAssertEqual(plan.environment["EXTRA"], "hello world")
        XCTAssertEqual(plan.environment["THIRD"], "override-suffix")
    }

    func testInvalidEnvironmentLineIsReportedWithLineNumber() {
        XCTAssertThrowsError(
            try CommandLineLaunchPlanner.plan(
                settings: CommandLineSettings(command: "env", environmentText: "not an assignment"),
                projectRoot: projectRoot
            )
        ) { error in
            guard case IdeaLightRunError.invalidConfiguration(let detail) = error else {
                return XCTFail("期望 invalidConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("第 1 行"), detail)
        }
    }

    func testSettingsRoundTripAndRunnableFlag() throws {
        let settings = CommandLineSettings(
            command: "  npm run dev\n",
            workingDirectory: "sub",
            environmentText: "A=1"
        )
        XCTAssertTrue(settings.isRunnable)
        XCTAssertEqual(settings.trimmedCommand, "npm run dev")

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CommandLineSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    /// 计划必须真的能跑：登录 zsh 的启动文件再复杂，最终 stdout / 工作目录仍要正确。
    func testPlanExecutesThroughManagedProcessSession() throws {
        let plan = try CommandLineLaunchPlanner.plan(
            settings: CommandLineSettings(command: "printf 'command-line-ok\\n'; pwd"),
            projectRoot: projectRoot
        )
        let session = try ManagedProcessSession(
            configKey: "command-line-test",
            configName: "命令行",
            plan: plan
        )
        var received: [LogLine] = []
        let lock = NSLock()
        session.onLogLines = { batch in
            lock.lock()
            received += batch
            lock.unlock()
        }

        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 30), "命令行进程应在超时前结束")
        Thread.sleep(forTimeInterval: 0.4)

        lock.lock()
        let text = received.map(\.text).joined(separator: "\n")
        lock.unlock()
        XCTAssertTrue(text.contains("command-line-ok"), text)
        let physicalRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(
            text.contains(projectRoot.standardizedFileURL.path) || text.contains(physicalRoot),
            text
        )
        guard case .exited(let code) = session.state else {
            return XCTFail("期望 exited，实际：\(session.state)")
        }
        XCTAssertEqual(code, 0)
    }
}
