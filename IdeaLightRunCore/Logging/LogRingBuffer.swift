import Foundation

/// §37: 环形日志缓冲——绝对不能无限保存日志。
/// 单进程上限默认 20,000 行 / 10 MB，超出丢弃最早日志。
/// §103: pending 队列 + 外部定时 flush，避免每行打到 UI。
public final class LogRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var pending: [LogLine] = []
    private var totalBytes = 0

    public let maxLines: Int
    public let maxBytes: Int

    public init(maxLines: Int = 20_000, maxBytes: Int = 10 * 1024 * 1024) {
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }

    public func append(_ line: LogLine) {
        append([line])
    }

    public func append(_ newLines: [LogLine]) {
        guard !newLines.isEmpty else { return }
        lock.lock()
        for line in newLines {
            lines.append(line)
            totalBytes += line.text.utf8.count + 1
        }
        trimLocked()
        pending.append(contentsOf: newLines)
        lock.unlock()
    }

    /// 批量裁剪：一次算出要丢多少行，一次 `removeFirst(k)`。
    /// 原实现是 `while 超限 { lines.removeFirst() }`——每丢一行都要把整个数组尾部
    /// 前移一格，缓冲满之后每来一行就是 O(上限)，十万行级别的日志会让 IO 线程把
    /// 时间全花在搬移上（行数、字节数双上限下尤其明显）。
    private func trimLocked() {
        // 行数上限决定至少丢这么多
        var k = lines.count > maxLines ? lines.count - maxLines : 0
        for index in 0..<k {
            totalBytes -= lines[index].text.utf8.count + 1
        }
        // 字节上限可能要求丢得更多（单行很长的日志光看行数不够）
        while k < lines.count, totalBytes > maxBytes {
            totalBytes -= lines[k].text.utf8.count + 1
            k += 1
        }
        if k > 0 {
            lines.removeFirst(k)
        }
    }

    /// §103: 取走待推送的批次。
    public func drainPending() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        let batch = pending
        pending = []
        return batch
    }

    public func snapshot() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }

    public func clear() {
        lock.lock()
        lines = []
        pending = []
        totalBytes = 0
        lock.unlock()
    }
}
