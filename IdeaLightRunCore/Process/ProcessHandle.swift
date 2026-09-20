import Foundation

/// 构建阶段进程句柄：让 Stop 按钮能终止正在运行的 Maven 构建（对齐 IDEA：
/// 构建期点 Stop → 终止构建进程，不再启动 Java）。
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelledValue = false

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledValue
    }

    /// 构建进程是否仍存活。退出流程用它判断 SIGTERM 后是否还需要兜底 SIGKILL。
    public var hasLiveProcess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public init() {}

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func detach() {
        lock.lock()
        self.process = nil
        lock.unlock()
    }

    /// 发送 SIGTERM；对已退出的进程无副作用。
    public func terminate() {
        lock.lock()
        cancelledValue = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
    }

    /// 发送 SIGKILL（构建进程卡死时的兜底）。
    public func forceKill() {
        lock.lock()
        cancelledValue = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
