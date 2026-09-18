import Foundation

/// §42: 同一项目串行构建，不同项目允许并行。
public final class BuildGate: @unchecked Sendable {
    public static let shared = BuildGate()

    private struct Waiter {
        let key: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var busy: Set<String> = []
    private var waiters: [Waiter] = []

    private init() {}

    public func run<T: Sendable>(
        projectKey: String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire(projectKey)
        do {
            let value = try await operation()
            release(projectKey)
            return value
        } catch {
            release(projectKey)
            throw error
        }
    }

    private func acquire(_ key: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy.insert(key).inserted {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(Waiter(key: key, continuation: continuation))
            lock.unlock()
        }
    }

    private func release(_ key: String) {
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.key == key }) {
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume()
            return
        }
        busy.remove(key)
        lock.unlock()
    }
}
