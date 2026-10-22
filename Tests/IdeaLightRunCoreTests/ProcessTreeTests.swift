import XCTest
@testable import IdeaLightRunCore

/// §P0-2/3/4: 进程生命周期——PID 只在真正启动后发布、Stop 必须整棵树生效、
/// 取消先于进程挂上时不能漏杀。
final class ProcessTreeTests: XCTestCase {
    private func makePlan(_ executable: String, _ arguments: [String]) -> ExecutableLaunchPlan {
        ExecutableLaunchPlan(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    /// §P0-4: stop() 只 SIGTERM 根进程会留下孤儿（`mvn → java` 的 java 继续占端口）。
    /// 用 `sh -c 'sleep & sleep & wait'` 造一棵真实进程树，停止后树内成员必须全部退出。
    func testStopKillsEntireProcessTree() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan("/bin/sh", ["-c", "sleep 300 & sleep 300 & wait"])
        )
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 5) == false, "树根不应自动退出")
        let root = session.pid
        XCTAssertGreaterThan(root, 0)

        // 等子进程确实被 fork 出来
        var tree: [pid_t] = []
        let deadline = Date().addingTimeInterval(3)
        repeat {
            tree = ProcessTree.allPIDs(root: root)
            if tree.count >= 3 { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTAssertGreaterThanOrEqual(tree.count, 3, "快照应包含 sh 与两个 sleep，实际：\(tree)")

        session.stop()
        XCTAssertTrue(session.waitUntilExit(timeout: 10))

        // 根退出后 sleep 变孤儿（ppid=1），只能靠停止时的快照确认它们真的死了
        Thread.sleep(forTimeInterval: 0.3)
        for pid in tree where pid != root {
            XCTAssertFalse(ProcessTree.isAlive(pid), "子进程 \(pid) 未被终止，留下孤儿")
        }
    }

    /// §P0-3（会话层）：Stop 落在 init 与 start() 之间时先登记，
    /// start() 跑起进程后立即终止——进程不能因为「停止得早」就永远活着。
    func testStopBeforeStartStillTerminatesProcessOnceLaunched() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan("/bin/sleep", ["60"])
        )
        session.stop()
        XCTAssertEqual(session.state, .stopping, "start 之前收到 Stop 应先进入 stopping")

        var startedPID: Int32?
        session.onStarted = { startedPID = $0 }
        session.start()

        XCTAssertTrue(session.waitUntilExit(timeout: 10), "登记过的 Stop 必须在进程启动后生效")
        XCTAssertNotNil(startedPID, "进程确实跑起来过，onStarted 必须回调")
        guard case .exited = session.state else {
            return XCTFail("期望 exited，实际：\(session.state)")
        }
        XCTAssertNotEqual(session.state, .running)
    }

    /// §P0-3（句柄层）：cancel 先到、进程后挂上时，attach 的第一时间就要补刀。
    /// 回归——旧实现 attach 不看 cancelledValue，「Stop 后构建进程才 spawn」的
    /// 竞态会让 Maven 继续跑完整个构建。
    func testProcessHandleCancelBeforeAttachTerminatesNewProcess() throws {
        let handle = ProcessHandle()
        handle.terminate() // 取消发生在 attach 之前

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        handle.attach(process)

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(process.isRunning, "已取消的句柄挂上进程后必须立刻终止它")
        XCTAssertEqual(process.terminationStatus, Int32(SIGTERM))
    }

    /// §P0-3/§5.5: attach 发现已取消时也要走 SIGTERM→SIGKILL 升级，
    /// 不能只发一次 SIGTERM 就把忽略该信号的构建进程留在"停止中"。
    func testProcessHandleCancelBeforeAttachEscalatesToSIGKILL() throws {
        let handle = ProcessHandle()
        handle.terminate()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 60"]
        try process.run()
        // 等 trap 生效再挂句柄，确保 SIGTERM 真的被忽略
        Thread.sleep(forTimeInterval: 0.2)
        handle.attach(process)

        let deadline = Date().addingTimeInterval(6)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(process.isRunning, "忽略 SIGTERM 的进程必须在升级后被杀掉")
        XCTAssertEqual(process.terminationStatus, Int32(SIGKILL))
    }

    /// ProcessTree.allPIDs 对不存在/已退出的 root 应返回空，不得误伤无关进程。
    func testAllPIDsOfInvalidRootIsEmpty() {
        XCTAssertEqual(ProcessTree.allPIDs(root: -1), [])
        XCTAssertEqual(ProcessTree.allPIDs(root: 0), [])
        // pid 1（launchd）永远存活，但拿它当 root 只会返回它自己——这里只验证不崩溃且包含自身
        XCTAssertTrue(ProcessTree.allPIDs(root: ProcessInfo.processInfo.processIdentifier)
            .contains(ProcessInfo.processInfo.processIdentifier))
    }
}
