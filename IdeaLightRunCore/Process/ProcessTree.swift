import Darwin
import Foundation

/// §P0-4: 进程树信号。Foundation 的 `Process` 不暴露 setpgid，无法给子进程
/// 建独立进程组；`mvn → java → helper` 这类链上只 SIGTERM 根进程会留下孤儿
/// （继续占端口、写文件）。这里用 sysctl(KERN_PROC) 按 ppid 收集整棵树，
/// 逐个投递信号；先拿快照再补刀——根进程死后孤儿子进程会被 reparent 到
/// launchd（ppid=1），再按树找就找不到了。
public enum ProcessTree {
    /// root 及其全部后代（BFS）。root 不在存活表里时返回空数组。
    public static func allPIDs(root: pid_t) -> [pid_t] {
        guard root > 0 else { return [] }
        let entries = livingProcesses()
        guard entries.contains(where: { $0.pid == root }) else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for entry in entries where entry.ppid > 0 {
            childrenByParent[entry.ppid, default: []].append(entry.pid)
        }

        var result: [pid_t] = [root]
        var queue: [pid_t] = [root]
        while let current = queue.popLast() {
            for child in childrenByParent[current] ?? [] where !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// 向 root 及其全部后代发送信号。
    public static func signal(root: pid_t, sig: Int32) {
        for pid in allPIDs(root: root) {
            kill(pid, sig)
        }
    }

    /// §P0-4/§5.5: 统一停止流程——先整棵树 SIGTERM，等待 `escalationSeconds`
    /// 后仍有幸存者再 SIGKILL，不把"要不要强杀"留给用户兜底。异步返回。
    public static func terminate(root: pid_t, escalationSeconds: Double = 3.0) {
        let snapshot = allPIDs(root: root)
        guard !snapshot.isEmpty else { return }
        for pid in snapshot {
            kill(pid, SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + escalationSeconds) {
            // 根已退出时子进程变孤儿（ppid=1），按启动时的快照逐个补刀
            for pid in snapshot where isAlive(pid) {
                kill(pid, SIGKILL)
            }
            // TERM→KILL 窗口内新 fork 的后代：根还活着时才能按树找到
            guard isAlive(root) else { return }
            for pid in allPIDs(root: root) where isAlive(pid) {
                kill(pid, SIGKILL)
            }
        }
    }

    /// kill(pid, 0) 探活：0 表示存活；EPERM 表示存活但无权限发信号。
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - 内部

    private typealias ProcessEntry = (pid: pid_t, ppid: pid_t)

    /// KERN_PROC_ALL 拿当前进程表。进程表随时在变，缓冲区不够会 ENOMEM，重试并加余量。
    private static func livingProcesses() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        for _ in 0..<3 {
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 64
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var bufferSize = capacity * MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 3, &buffer, &bufferSize, nil, 0) == 0 else { return [] }
            if bufferSize <= capacity * MemoryLayout<kinfo_proc>.stride / 2 {
                // 只用到一半以下：快照期间进程表没有明显增长，结果可信
                let count = bufferSize / MemoryLayout<kinfo_proc>.stride
                return buffer.prefix(count).map { proc in
                    (pid: proc.kp_proc.p_pid, ppid: proc.kp_eproc.e_ppid)
                }
            }
            size *= 2
        }
        return []
    }
}
