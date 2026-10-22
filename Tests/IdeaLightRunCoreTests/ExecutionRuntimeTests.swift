import XCTest
@testable import IdeaLightRunCore

/// §4.2: GUI / CLI 只提交 `PreparedExecution`，由 ExecutionRuntime 统一处理
/// 进程启动、日志、PID、终态与停止。
final class ExecutionRuntimeTests: XCTestCase {
    private func plan(_ executable: String, _ arguments: [String]) -> ExecutableLaunchPlan {
        ExecutableLaunchPlan(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    private func makeRuntime(
        _ executable: String,
        _ arguments: [String],
        name: String = "Test"
    ) throws -> ExecutionRuntime {
        try ExecutionRuntime(
            configKey: "test::\(name)",
            configName: name,
            execution: .process(plan(executable, arguments))
        )
    }

    func testForwardsLogsPIDAndExitCode() throws {
        let runtime = try makeRuntime("/bin/echo", ["hello-runtime"])

        var states: [ProcessState] = []
        var startedPIDs: [Int32] = []
        var received: [LogLine] = []
        let lock = NSLock()
        runtime.setHandlers(
            onStarted: { pid in
                lock.lock(); startedPIDs.append(pid); lock.unlock()
            },
            onState: { state in
                lock.lock(); states.append(state); lock.unlock()
            },
            onLogLines: { batch in
                lock.lock(); received += batch; lock.unlock()
            }
        )

        runtime.start()
        XCTAssertTrue(runtime.waitUntilExit(timeout: 10))
        Thread.sleep(forTimeInterval: 0.4)

        lock.lock()
        let observedStates = states
        let pids = startedPIDs
        let text = received.map(\.text).joined(separator: "\n")
        lock.unlock()

        XCTAssertEqual(runtime.state, .exited(0))
        XCTAssertEqual(pids.first, runtime.pid)
        XCTAssertTrue(pids.allSatisfy { $0 > 0 })
        XCTAssertTrue(observedStates.contains(.exited(0)), "\(observedStates)")
        XCTAssertTrue(text.contains("hello-runtime"), text)
    }

    func testStopTerminatesRuntime() throws {
        let runtime = try makeRuntime("/bin/sleep", ["100"])
        runtime.start()
        XCTAssertFalse(runtime.waitUntilExit(timeout: 2), "sleep 100 不应自行退出")
        runtime.stop()
        XCTAssertTrue(runtime.waitUntilExit(timeout: 5))
        XCTAssertTrue(runtime.state.isTerminal)
        XCTAssertFalse(runtime.isRunning)
    }

    func testCompoundExecutionStartsAllMembersWithIndependentPIDsAndLogs() throws {
        let runtime = try makeCompoundRuntime([
            ("Alpha", "/bin/echo", ["alpha-log"]),
            ("Beta", "/bin/echo", ["beta-log"]),
        ])
        let lock = NSLock()
        var pids: [String: Int32] = [:]
        var memberLogs: [String: [String]] = [:]
        var rootLogs: [String] = []

        runtime.setHandlers(
            onState: { _ in },
            onLogLines: { batch in
                lock.lock(); rootLogs += batch.map(\.text); lock.unlock()
            },
            onCompoundMember: { event in
                lock.lock()
                switch event.kind {
                case .started(let pid):
                    pids[event.memberName] = pid
                case .logLines(let lines):
                    memberLogs[event.memberName, default: []] += lines.map(\.text)
                case .state:
                    break
                }
                lock.unlock()
            }
        )

        runtime.start()
        XCTAssertTrue(runtime.waitUntilExit(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)

        lock.lock()
        let observedPIDs = pids
        let logs = memberLogs
        let merged = rootLogs
        lock.unlock()

        XCTAssertEqual(observedPIDs.count, 2, "每个成员都要有自己的 PID")
        XCTAssertNotEqual(observedPIDs["Alpha"], observedPIDs["Beta"])
        XCTAssertTrue(observedPIDs.values.allSatisfy { $0 > 0 })
        XCTAssertTrue(logs["Alpha", default: []].contains { $0.contains("alpha-log") })
        XCTAssertTrue(logs["Beta", default: []].contains { $0.contains("beta-log") })
        XCTAssertFalse(logs["Alpha", default: []].contains { $0.contains("beta-log") }, "成员日志不能串台")
        XCTAssertTrue(merged.contains { $0.contains("[Alpha]") && $0.contains("alpha-log") }, "\(merged)")
        XCTAssertTrue(merged.contains { $0.contains("[Beta]") && $0.contains("beta-log") }, "\(merged)")
        XCTAssertEqual(runtime.state, .exited(0))
    }

    func testCompoundStopStopsEveryMember() throws {
        let runtime = try makeCompoundRuntime([
            ("One", "/bin/sleep", ["100"]),
            ("Two", "/bin/sleep", ["100"]),
        ])
        runtime.start()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(runtime.members.allSatisfy { $0.pid > 0 })

        runtime.stop()
        XCTAssertTrue(runtime.waitUntilExit(timeout: 8), "分组 Stop 必须停掉所有成员")
        XCTAssertTrue(runtime.members.allSatisfy { $0.state.isTerminal })
        XCTAssertTrue(runtime.state.isTerminal)
    }

    func testCompoundForceKillTerminatesEveryMember() throws {
        let runtime = try makeCompoundRuntime([
            ("One", "/bin/sleep", ["100"]),
            ("Two", "/bin/sleep", ["100"]),
        ])
        runtime.start()
        Thread.sleep(forTimeInterval: 0.4)

        runtime.forceKill()
        XCTAssertTrue(runtime.waitUntilExit(timeout: 8))
        XCTAssertTrue(runtime.members.allSatisfy { $0.state.isTerminal })
    }

    /// 一个成员异常结束后，其余成员不能继续跑，否则会留下半套服务。
    func testCompoundPartialFailureStopsRemainingMembers() throws {
        let runtime = try makeCompoundRuntime([
            ("Fail", "/usr/bin/false", []),
            ("Server", "/bin/sleep", ["100"]),
        ])
        runtime.start()
        XCTAssertTrue(runtime.waitUntilExit(timeout: 8), "失败清理后组合必须进入终态")
        XCTAssertTrue(runtime.members.allSatisfy { $0.state.isTerminal })
        XCTAssertEqual(runtime.state, .exited(1), "失败成员的退出码要保留")
    }

    func testEmptyCompoundIsRejected() {
        XCTAssertThrowsError(try ExecutionRuntime(
            configKey: "all",
            configName: "All",
            execution: .compound(CompoundExecutionPlan(name: "All", members: []))
        )) { error in
            guard case IdeaLightRunError.invalidConfiguration = error else {
                return XCTFail("期望 invalidConfiguration，实际：\(error)")
            }
        }
    }

    private func makeCompoundRuntime(
        _ members: [(String, String, [String])]
    ) throws -> ExecutionRuntime {
        let plans = members.map { name, executable, arguments in
            CompoundMemberPlan(
                name: name,
                configurationKey: "test::\(name)",
                execution: .process(plan(executable, arguments))
            )
        }
        return try ExecutionRuntime(
            configKey: "test::All",
            configName: "All",
            execution: .compound(CompoundExecutionPlan(name: "All", members: plans))
        )
    }

    // MARK: - Before Launch 的同步执行

    func testRunUntilExitSucceeds() async throws {
        var lines: [String] = []
        let lock = NSLock()
        try await ExecutionRuntime.runUntilExit(
            execution: .process(plan("/bin/echo", ["referenced-ok"])),
            configName: "Referenced",
            processHandle: nil,
            log: { line in
                lock.lock(); lines.append(line.text); lock.unlock()
            }
        )
        lock.lock()
        let text = lines.joined(separator: "\n")
        lock.unlock()
        XCTAssertTrue(text.contains("referenced-ok"), text)
    }

    func testRunUntilExitNonZeroFailsAsBuildFailure() async throws {
        do {
            try await ExecutionRuntime.runUntilExit(
                execution: .process(plan("/usr/bin/false", [])),
                configName: "Referenced",
                processHandle: nil,
                log: { _ in }
            )
            XCTFail("非零退出应中止本次启动")
        } catch let error as IdeaLightRunError {
            guard case .buildFailed(let detail) = error else {
                return XCTFail("期望 buildFailed，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("Referenced"), detail)
        }
    }

    func testRunUntilExitHonoursOuterStop() async throws {
        let handle = ProcessHandle()
        let task = Task {
            try await ExecutionRuntime.runUntilExit(
                execution: .process(plan("/bin/sleep", ["100"])),
                configName: "Referenced",
                processHandle: handle,
                log: { _ in }
            )
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        handle.terminate()

        do {
            try await task.value
            XCTFail("停止后不应正常完成")
        } catch let error as IdeaLightRunError {
            guard case .launchCancelled = error else {
                return XCTFail("期望 launchCancelled，实际：\(error)")
            }
        }
    }
}
