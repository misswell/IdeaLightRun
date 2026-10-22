import XCTest
@testable import IdeaLightRunCore

final class ManagedProcessSessionTests: XCTestCase {
    func makePlan(executable: String, arguments: [String]) -> ExecutableLaunchPlan {
        ExecutableLaunchPlan(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    func testCapturesStdoutAndExitCode() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/echo", arguments: ["hello-lightrun"])
        )
        var received: [LogLine] = []
        let lock = NSLock()
        session.onLogLines = { batch in
            lock.lock()
            received += batch
            lock.unlock()
        }
        session.start()
        let exited = session.waitUntilExit(timeout: 10)
        XCTAssertTrue(exited)
        // 等 flush 周期送达
        Thread.sleep(forTimeInterval: 0.4)
        lock.lock()
        let text = received.map(\.text).joined(separator: "\n")
        lock.unlock()
        XCTAssertTrue(text.contains("hello-lightrun"), "应捕获 stdout，实际：\(text)")
        guard case .exited(let code) = session.state else {
            return XCTFail("期望 exited，实际：\(session.state)")
        }
        XCTAssertEqual(code, 0)
    }

    /// §33: stop() → SIGTERM → 进程退出
    func testStopTerminatesProcess() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sleep", arguments: ["100"])
        )
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 5) == false, "sleep 100 不应自动退出")
        session.stop()
        XCTAssertTrue(session.waitUntilExit(timeout: 5), "SIGTERM 后应退出")
        guard case .exited = session.state else {
            return XCTFail("期望 exited，实际：\(session.state)")
        }
    }

    /// §P0-4: Stop 落在 start() 之前时，进程跑起来后立即终止；
    /// 整个过程不得对外发布 .running——否则界面会闪一下"运行中"再退出。
    func testStopBeforeStartNeverPublishesRunning() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sleep", arguments: ["100"])
        )
        var states: [ProcessState] = []
        let lock = NSLock()
        session.onState = { state in
            lock.lock()
            states.append(state)
            lock.unlock()
        }

        session.stop()
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 10), "启动前的 Stop 必须在进程跑起来后生效")
        lock.lock()
        let observed = states
        lock.unlock()
        XCTAssertFalse(observed.contains(.running), "不得发布虚假的运行态：\(observed)")
        XCTAssertTrue(session.state.isTerminal)
    }

    /// §P0-4: Stop 必须幂等。重复点击不能改变状态，也不能让进程在终态后"复活"。
    func testRepeatedStopIsIdempotent() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sleep", arguments: ["100"])
        )
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 5) == false)
        session.stop()
        session.stop()
        session.stop()
        XCTAssertTrue(session.waitUntilExit(timeout: 10))
        let terminalState = session.state
        XCTAssertTrue(terminalState.isTerminal, "\(terminalState)")

        session.stop()
        session.forceKill()
        XCTAssertEqual(session.state, terminalState, "终态后的 Stop / Force Kill 必须是无操作")
    }

    func testFailedLaunchReportsFailure() throws {
        // 使用不存在的 java 可执行文件 → init 直接抛错
        XCTAssertThrowsError(try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/nonexistent/java", arguments: [])
        ))
    }

    /// 可执行但无法 spawn 的目标：run() 抛错时写入的日志也必须送达 UI。
    /// 回归——flush 定时器原先在 run() 之后才 resume，失败路径上的日志永远留在缓冲区。
    func testFailedStartStillDeliversLogs() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightrun-bogus-\(UUID().uuidString)")
        try Data("#!/nonexistent/interpreter\n".utf8).write(to: bogus)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bogus.path)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: bogus.path, arguments: [])
        )
        var received: [LogLine] = []
        let lock = NSLock()
        session.onLogLines = { batch in
            lock.lock()
            received += batch
            lock.unlock()
        }

        session.start()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock()
            let delivered = received.contains { $0.text.contains("启动失败") }
            lock.unlock()
            if delivered { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        lock.lock()
        let text = received.map(\.text).joined(separator: "\n")
        lock.unlock()
        XCTAssertTrue(text.contains("启动失败"), "启动失败的原因必须出现在控制台，实际：\(text)")
        guard case .failed = session.state else {
            return XCTFail("期望 failed，实际：\(session.state)")
        }
    }

    /// start() 从未调用过也必须能安全释放：定时器在 init 就 resume，
    /// 否则 deinit 里 cancel 一个挂起的 DispatchSource 会直接崩溃。
    func testReleaseWithoutStartIsSafe() throws {
        for _ in 0..<20 {
            let session = try ManagedProcessSession(
                configKey: "test", configName: "test",
                plan: makePlan(executable: "/bin/echo", arguments: ["unused"])
            )
            withExtendedLifetime(session) {}
        }
    }

    func testLogBufferCapUnderHeavyOutput() throws {
        // 大量输出时环形缓冲不应无限增长（§37）
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sh", arguments: ["-c", "for i in $(seq 1 2000); do echo line-$i; done"])
        )
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 30))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThanOrEqual(session.logBuffer.count, 20_000)
        XCTAssertGreaterThan(session.logBuffer.count, 0)
    }

    /// 回归：readerGroup.notify 原先在 enter() 之前注册，计数为 0 时它会立即投递，
    /// 于是进程刚起来就被判成 .exited(0)——服务在跑，列表却显示"已退出"。
    func testLongRunningProcessIsNotReportedExited() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sleep", arguments: ["30"])
        )
        session.start()
        // 旧实现里 notify 立即投递 + 退出码兜底为 0，2 秒后就会显示"已退出 (0)"
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(session.state, .running, "进程仍在运行时不得报退出")

        session.stop()
        XCTAssertTrue(session.waitUntilExit(timeout: 10))
    }

    /// 回归：子进程自行关闭 stdout（管道 EOF）不等于进程退出，退出码必须来自真实退出。
    func testStdoutClosedWhileProcessAlive() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sh", arguments: ["-c", "exec 1>&-; sleep 1; exit 7"])
        )
        session.start()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(session.state, .running, "stdout 关闭后进程还活着，不能报退出")

        XCTAssertTrue(session.waitUntilExit(timeout: 10))
        XCTAssertEqual(session.state, .exited(7))
    }

    /// 孙进程继承管道写端会让 EOF 迟迟不到；状态必须以进程退出为准，不能卡在"运行中"。
    func testExitDetainedByInheritedPipeStillReports() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sh", arguments: ["-c", "sleep 2 & exit 3"])
        )
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 5), "父进程已退出，不能被挂起的管道拖住状态")
        XCTAssertEqual(session.state, .exited(3))
    }

    /// §7: 会话不解释参数，只逐项传递——含空格的参数也不会被拆开或改写。
    func testArgumentsArePassedVerbatim() throws {
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/echo", arguments: ["-cp", "/tmp/a jar:/tmp/b.jar", "com.example.Main"])
        )
        var received: [LogLine] = []
        let lock = NSLock()
        session.onLogLines = { batch in
            lock.lock()
            received += batch
            lock.unlock()
        }
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 10))
        Thread.sleep(forTimeInterval: 0.4)
        lock.lock()
        // 只看进程自己的输出：会话另外写了一条 "[IdeaLightRun] 进程已启动" 系统行。
        let text = received.filter { $0.stream == .stdout }.map(\.text).joined(separator: "\n")
        lock.unlock()
        XCTAssertEqual(text, "-cp /tmp/a jar:/tmp/b.jar com.example.Main")
    }

    /// §7: 计划登记的临时产物（@argfile 等）在进程进入终态时由会话清掉。
    func testTemporaryArtifactsRemovedOnExit() throws {
        let artifact = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightrun-argfile-\(UUID().uuidString)")
        try Data("-cp /tmp/a.jar".utf8).write(to: artifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))

        var plan = makePlan(executable: "/bin/echo", arguments: ["done"])
        plan.temporaryArtifacts = [artifact]
        let session = try ManagedProcessSession(configKey: "test", configName: "test", plan: plan)
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 10))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.path),
            "会话结束后临时文件必须消失，否则每次启动都在攒垃圾"
        )
    }
}

extension ManagedProcessSessionTests {
    /// §103 复测：进程边跑边打印时，日志必须在一个 flush 周期内（≈100ms）送达回调，
    /// 而不是压到进程退出才一次性出现。
    func testStreamingArrivesDuringProcessLifetime() throws {
        // 每秒打印一行、共 4 行；打印完成后自身退出
        let session = try ManagedProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import time\nfor i in range(4):\n    print(f'line-{i}', flush=True)\n    time.sleep(1)\n"]
            )
        )
        var arrivals: [(text: String, at: TimeInterval)] = []
        let lock = NSLock()
        session.onLogLines = { batch in
            lock.lock()
            let now = Date().timeIntervalSinceReferenceDate
            arrivals += batch.map { ($0.text, now) }
            lock.unlock()
        }
        let startedAt = Date().timeIntervalSinceReferenceDate
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 15))
        Thread.sleep(forTimeInterval: 0.5) // 等最后一个 flush 周期

        lock.lock()
        defer { lock.unlock() }
        let lines = arrivals.filter { $0.text.hasPrefix("line-") }
        XCTAssertEqual(lines.count, 4, "4 行都应送达，实际：\(arrivals.map(\.text))")
        for (index, arrival) in lines.enumerated() {
            // line-i 在进程启动后第 i 秒打印；超过 +2s 才到就说明流式断了
            let delay = arrival.at - startedAt - Double(index)
            XCTAssertLessThan(delay, 2.0, "line-\(index) 迟到 \(delay)s，日志被攒到退出才吐")
        }
    }
}
