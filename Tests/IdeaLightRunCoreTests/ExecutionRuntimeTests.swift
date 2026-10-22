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

    func testCompoundExecutionIsRejectedUntilM3() {
        let compound = CompoundExecutionPlan(name: "All", members: [])
        XCTAssertThrowsError(try ExecutionRuntime(
            configKey: "all",
            configName: "All",
            execution: .compound(compound)
        )) { error in
            guard case IdeaLightRunError.unsupportedConfiguration(let detail) = error else {
                return XCTFail("期望 unsupportedConfiguration，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("Milestone 3"), detail)
        }
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
