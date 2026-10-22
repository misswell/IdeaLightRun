import XCTest
@testable import IdeaLightRunCore

/// M5: 从构建日志里提取测试结果。Surefire 与 Gradle 的输出格式不同，
/// 但没有汇总时必须让上层知道“无法确认测试是否运行”，不能默认成功。
final class TestOutcomeMonitorTests: XCTestCase {
    func testMavenPerClassLinesAreNotAddedToTheResultsBlock() {
        let monitor = TestOutcomeMonitor()
        monitor.consume("[INFO] Running com.example.ATest")
        monitor.consume("[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.01 s")
        monitor.consume("[INFO] Running com.example.BTest")
        monitor.consume("[INFO] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.01 s")
        monitor.consume("[INFO] Results:")
        monitor.consume("[INFO] Tests run: 5, Failures: 1, Errors: 0, Skipped: 0")
        let summary = monitor.snapshot()
        XCTAssertTrue(summary.hasReport)
        XCTAssertEqual(summary.total, 5, "只统计 Results 段，逐类的行不能重复累加")
        XCTAssertEqual(summary.failures, 1)
    }

    func testLegacySurefireResultsMarkerIsRecognized() {
        let monitor = TestOutcomeMonitor()
        monitor.consume("[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.01 s")
        monitor.consume("[INFO] Results :")
        monitor.consume("[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0")
        let summary = monitor.snapshot()
        XCTAssertTrue(summary.hasReport)
        XCTAssertEqual(summary.total, 2)
    }

    func testMavenMultiModuleResultsAreAggregated() {
        let monitor = TestOutcomeMonitor()
        monitor.consume([
            LogLine(stream: .stdout, text: "[INFO] Results:"),
            LogLine(stream: .stdout, text: "[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0"),
            LogLine(stream: .stdout, text: "[INFO] Results:"),
            LogLine(stream: .stdout, text: "[INFO] Tests run: 5, Failures: 1, Errors: 2, Skipped: 3"),
        ])
        let summary = monitor.snapshot()
        XCTAssertEqual(summary.total, 7)
        XCTAssertEqual(summary.failures, 1)
        XCTAssertEqual(summary.errors, 2)
        XCTAssertEqual(summary.skipped, 3)
        XCTAssertEqual(summary.failedCount, 3)
    }

    func testMavenFallbackUsesLastCountsWhenResultsMarkerIsAbsent() {
        let monitor = TestOutcomeMonitor()
        monitor.consume("[INFO] Tests run: 4, Failures: 0, Errors: 0, Skipped: 1")
        let summary = monitor.snapshot()
        XCTAssertTrue(summary.hasReport)
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.skipped, 1)
    }

    func testGradleSummaryIsParsed() {
        let monitor = TestOutcomeMonitor()
        monitor.consume("[IdeaLightRun-Test] SUMMARY total=9 failed=2 skipped=1")
        let summary = monitor.snapshot()
        XCTAssertTrue(summary.hasReport)
        XCTAssertEqual(summary.total, 9)
        XCTAssertEqual(summary.failedCount, 2)
        XCTAssertEqual(summary.skipped, 1)
    }

    func testNoTestsMessagesAreDetected() {
        let monitor = TestOutcomeMonitor()
        monitor.consume("[ERROR] No tests were executed!")
        XCTAssertTrue(monitor.snapshot().noTestsDetected)

        let gradle = TestOutcomeMonitor()
        gradle.consume("Execution failed for task ':app:test'.")
        gradle.consume("No tests found for given includes: [com.example.GhostTest]")
        XCTAssertTrue(gradle.snapshot().noTestsDetected)
        XCTAssertFalse(gradle.snapshot().didRunAnyTest)
    }

    func testEmptyMonitorHasNoReport() {
        let summary = TestOutcomeMonitor().snapshot()
        XCTAssertFalse(summary.hasReport)
        XCTAssertFalse(summary.didRunAnyTest)
        XCTAssertEqual(summary.total, 0)
    }
}
