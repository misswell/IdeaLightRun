import Foundation

/// §42: 同一项目串行构建，不同项目允许并行。
public final class BuildGate: @unchecked Sendable {
    public static let shared = BuildGate()

    /// §3.7: Before Launch 引用的运行配置会在同一项目内再次进入构建阶段。
    /// 没有持有者身份就会自锁：外层还没释放，内层永远等不到（同项目 = 同 key）。
    public struct Owner: Hashable, Sendable {
        public let id: UUID

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }

    private struct Waiter {
        let key: String
        let owner: Owner
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct Hold {
        let owner: Owner
        var depth: Int
    }

    private let lock = NSLock()
    private var holds: [String: Hold] = [:]
    private var waiters: [Waiter] = []

    private init() {}

    public func run<T: Sendable>(
        projectKey: String,
        owner: Owner = Owner(),
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire(projectKey, owner: owner)
        do {
            let value = try await operation()
            release(projectKey, owner: owner)
            return value
        } catch {
            release(projectKey, owner: owner)
            throw error
        }
    }

    /// 当前持有该 key 的构建链深度，供嵌套调用复用同一持有者。
    public func ownerOf(_ key: String) -> Owner? {
        lock.lock()
        defer { lock.unlock() }
        return holds[key]?.owner
    }

    private func acquire(_ key: String, owner: Owner) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if let hold = holds[key] {
                if hold.owner == owner {
                    holds[key] = Hold(owner: owner, depth: hold.depth + 1)
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(key: key, owner: owner, continuation: continuation))
                lock.unlock()
                return
            }
            holds[key] = Hold(owner: owner, depth: 1)
            lock.unlock()
            continuation.resume()
        }
    }

    private func release(_ key: String, owner: Owner) {
        lock.lock()
        guard let hold = holds[key], hold.owner == owner else {
            lock.unlock()
            return
        }
        if hold.depth > 1 {
            holds[key] = Hold(owner: owner, depth: hold.depth - 1)
            lock.unlock()
            return
        }
        if let index = waiters.firstIndex(where: { $0.key == key }) {
            let waiter = waiters.remove(at: index)
            holds[key] = Hold(owner: waiter.owner, depth: 1)
            lock.unlock()
            waiter.continuation.resume()
            return
        }
        holds.removeValue(forKey: key)
        lock.unlock()
    }
}
