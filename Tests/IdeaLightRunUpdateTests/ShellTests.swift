import Foundation
import XCTest

@testable import IdeaLightRunUpdate

/// 更新流程靠外部命令做验签/公证校验；这些命令必须被**边跑边读**，
/// 否则输出一多就互等成死锁（v0.1.39 的「永远正在安装」就是这么来的）。
final class ShellTests: XCTestCase {
    func testDrainsOutputLargerThanPipeBuffer() throws {
        // 128 KB 远大于 macOS 管道的 16 KB 缓冲。旧实现先 waitUntilExit 再读，
        // 子进程写满缓冲后卡在 write，父进程卡在 wait，永远不返回。
        let outcome = try Shell.run(
            "/bin/sh",
            ["-c", "yes x | tr -d '\\n' | head -c 131072"],
            timeout: 30
        )
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.output.count, 131_072)
    }

    func testCodesignVerboseOutputDoesNotDeadlock() throws {
        // macOS 27 上 `codesign --display --verbose=4` 在管道没人读时会卡死。
        // 这是实际把更新面板挂在「正在安装」的那条命令。
        let outcome = try Shell.run(
            "/usr/bin/codesign",
            ["--display", "--verbose=4", "/bin/echo"],
            timeout: 30
        )
        XCTAssertEqual(outcome.status, 0)
        XCTAssertFalse(outcome.output.isEmpty)
    }

    func testKillsACommandThatExceedsItsTimeout() throws {
        let started = Date()
        let outcome = try Shell.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertEqual(outcome.status, Shell.Outcome.timedOutStatus)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertTrue(outcome.output.contains("未结束"))
    }
}
