import XCTest
@testable import IdeaLightRunCore

final class LogRingBufferTests: XCTestCase {
    func testAppendAndSnapshot() {
        let buffer = LogRingBuffer()
        buffer.append(LogLine(stream: .stdout, text: "hello"))
        buffer.append(LogLine(stream: .stderr, text: "world"))
        XCTAssertEqual(buffer.snapshot().map(\.text), ["hello", "world"])
        XCTAssertEqual(buffer.count, 2)
    }

    /// §37: 行数上限，丢弃最早日志
    func testLineCapDropsOldest() {
        let buffer = LogRingBuffer(maxLines: 5, maxBytes: 1_000_000)
        for index in 0..<10 {
            buffer.append(LogLine(stream: .stdout, text: "line-\(index)"))
        }
        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.count, 5)
        XCTAssertEqual(snapshot.first?.text, "line-5")
        XCTAssertEqual(snapshot.last?.text, "line-9")
    }

    /// §37: 字节上限
    func testByteCapDropsOldest() {
        let buffer = LogRingBuffer(maxLines: 1000, maxBytes: 40)
        for index in 0..<10 {
            buffer.append(LogLine(stream: .stdout, text: "0123456789"))  // 11 bytes each
        }
        // 40 字节上限 → 最多保留 3 条
        XCTAssertEqual(buffer.count, 3)
    }

    /// §103: drainPending 取走待推送批次
    func testDrainPending() {
        let buffer = LogRingBuffer()
        buffer.append(LogLine(stream: .stdout, text: "a"))
        buffer.append(LogLine(stream: .stdout, text: "b"))
        XCTAssertEqual(buffer.drainPending().count, 2)
        XCTAssertEqual(buffer.drainPending().count, 0, "drain 后应为空")
        // snapshot 仍然保留历史
        XCTAssertEqual(buffer.count, 2)
    }

    func testClear() {
        let buffer = LogRingBuffer()
        buffer.append(LogLine(stream: .stdout, text: "x"))
        buffer.clear()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.drainPending().count, 0)
    }
}
