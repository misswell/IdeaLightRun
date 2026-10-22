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

    /// §P0-3: attach 必须尊重此前已发生的 cancel——取消先到、进程后挂上时，
    /// 拿到进程的第一时间就终止它，不能让"已取消"的构建继续跑完。
    /// 终止走与正常 Stop 相同的 SIGTERM→SIGKILL 升级流程：构建进程忽略 SIGTERM 时
    /// 不能永远停在"停止中"。
    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelledValue
        lock.unlock()

        if shouldTerminate {
            ProcessTree.terminate(root: process.processIdentifier, escalationSeconds: 3)
        }
    }

    func detach() {
        lock.lock()
        self.process = nil
        lock.unlock()
    }

    /// 发送 SIGTERM（含整棵子进程树）；对已退出的进程无副作用。
    /// 3 秒后仍有幸存者自动升级 SIGKILL（§5.5 统一停止流程）。
    public func terminate() {
        lock.lock()
        cancelledValue = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        ProcessTree.terminate(root: process.processIdentifier, escalationSeconds: 3)
    }

    /// 发送 SIGKILL（构建进程卡死时的兜底），作用于整棵子进程树。
    public func forceKill() {
        lock.lock()
        cancelledValue = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        ProcessTree.signal(root: process.processIdentifier, sig: SIGKILL)
    }
}
