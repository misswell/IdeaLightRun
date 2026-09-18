import XCTest
@testable import IdeaLightRunCore

final class ProcessSessionTests: XCTestCase {
    func makePlan(executable: String, arguments: [String]) -> JavaLaunchPlan {
        JavaLaunchPlan(
            javaExecutable: URL(fileURLWithPath: executable),
            vmArguments: [],
            classpath: [],
            mainClass: "",
            programArguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    func testCapturesStdoutAndExitCode() throws {
        let session = try ProcessSession(
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
        let session = try ProcessSession(
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

    func testFailedLaunchReportsFailure() throws {
        // 使用不存在的 java 可执行文件 → init 直接抛错
        XCTAssertThrowsError(try ProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/nonexistent/java", arguments: [])
        ))
    }

    func testLogBufferCapUnderHeavyOutput() throws {
        // 大量输出时环形缓冲不应无限增长（§37）
        let session = try ProcessSession(
            configKey: "test", configName: "test",
            plan: makePlan(executable: "/bin/sh", arguments: ["-c", "for i in $(seq 1 2000); do echo line-$i; done"])
        )
        session.start()
        XCTAssertTrue(session.waitUntilExit(timeout: 30))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThanOrEqual(session.logBuffer.count, 20_000)
        XCTAssertGreaterThan(session.logBuffer.count, 0)
    }
}
