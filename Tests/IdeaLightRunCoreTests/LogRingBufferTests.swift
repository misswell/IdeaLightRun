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

    /// 批量裁剪必须和逐行裁剪得到完全一样的结果：行数上限、字节上限、
    /// 两者同时触发三种情况下保留的都是「最新的 N 行」。
    func testBatchTrimMatchesPerLineSemantics() {
        // 行数上限：一次塞进远超上限的行
        let lineCapped = LogRingBuffer(maxLines: 10, maxBytes: 100_000)
        lineCapped.append((0..<1_000).map { LogLine(stream: .stdout, text: "line-\($0)") })
        XCTAssertEqual(lineCapped.count, 10)
        XCTAssertEqual(lineCapped.snapshot().first?.text, "line-990")
        XCTAssertEqual(lineCapped.snapshot().last?.text, "line-999")

        // 字节上限：每行 11 字节，40 字节只能留 3 行
        let byteCapped = LogRingBuffer(maxLines: 1_000, maxBytes: 40)
        byteCapped.append((0..<10).map { _ in LogLine(stream: .stdout, text: "0123456789") })
        XCTAssertEqual(byteCapped.count, 3)

        // 行数没超但字节超了：k 必须由字节循环补足
        let mixed = LogRingBuffer(maxLines: 100, maxBytes: 40)
        mixed.append((0..<5).map { _ in LogLine(stream: .stdout, text: "0123456789") })
        XCTAssertEqual(mixed.count, 3)
    }

    /// 吞吐回归：十万行级别日志不能把 IO 线程拖垮。
    /// 旧实现每丢一行 `removeFirst()` 一次，缓冲满后每行 O(上限)，
    /// 20 万行在 2 万行上限下要搬移约 18 万 × 2 万次。
    func testHighVolumeAppendThroughput() {
        let buffer = LogRingBuffer(maxLines: 20_000, maxBytes: 10 * 1024 * 1024)
        let batch = (0..<500).map { LogLine(stream: .stdout, text: "2026-10-16 12:00:00.000 INFO  c.e.TgTenantApplication - 处理请求 #\($0) 耗时 12ms") }
        let started = Date()
        // 200 批 × 500 行 = 10 万行
        for _ in 0..<200 {
            buffer.append(batch)
            _ = buffer.drainPending()
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(buffer.count, 20_000, "上限必须生效")
        XCTAssertLessThan(elapsed, 2.0, "十万行写入耗时 \(elapsed)s，超过 2s 说明裁剪仍是逐行搬移")
    }
}
