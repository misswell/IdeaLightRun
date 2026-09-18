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
        while lines.count > maxLines || totalBytes > maxBytes {
            let removed = lines.removeFirst()
            totalBytes -= removed.text.utf8.count + 1
        }
        pending.append(contentsOf: newLines)
        lock.unlock()
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
