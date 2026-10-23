import CoreServices
import Foundation

/// FSEvents 只作为“可能有变化”的信号：真正的变更由会话重新快照并做指纹 diff。
/// 这样自己编译产生的输出、外部 IDEA 构建、编辑器原子保存不会重复触发同一批变更。
public final class HotReloadFileWatcher: @unchecked Sendable {
    private let roots: [String]
    private let latency: TimeInterval
    private let isRelevant: @Sendable (String) -> Bool
    private let onEvents: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "com.misswell.IdeaLightRun.hot-reload-fsevents", qos: .utility)

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var stopped = false

    public init(
        roots: [URL],
        latency: TimeInterval = 0.15,
        isRelevant: @escaping @Sendable (String) -> Bool,
        onEvents: @escaping @Sendable ([String]) -> Void
    ) {
        self.roots = roots.map { $0.standardizedFileURL.path }
        self.latency = max(0.05, latency)
        self.isRelevant = isRelevant
        self.onEvents = onEvents
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        guard stream == nil, !stopped, !roots.isEmpty else {
            lock.unlock()
            return
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            lock.unlock()
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            lock.unlock()
            return
        }
        stream = created
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let existing = stream
        stream = nil
        lock.unlock()
        guard let existing else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return }

        var relevant: [String] = []
        var requiresFullRescan = false
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            let mustScan = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                requiresFullRescan = true
            }
            if mustScan {
                requiresFullRescan = true
            }
            if isRelevant(path) {
                relevant.append(path)
            }
        }
        if requiresFullRescan {
            // 事件被内核丢弃 / 根目录被替换时路径列表不可信，直接让会话做一次全量快照。
            relevant.append(contentsOf: roots)
        }
        guard !relevant.isEmpty else { return }
        onEvents(Array(Set(relevant)).sorted())
    }

    private static let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info, eventCount > 0 else { return }
        let watcher = Unmanaged<HotReloadFileWatcher>.fromOpaque(info).takeUnretainedValue()

        var paths: [String] = []
        paths.reserveCapacity(Int(eventCount))
        // UseCFTypes 时 eventPaths 是 CFArray<CFString>。
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let count = min(Int(eventCount), CFArrayGetCount(array))
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let string = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            paths.append(string)
        }

        var flags: [FSEventStreamEventFlags] = []
        flags.reserveCapacity(Int(eventCount))
        for index in 0..<Int(eventCount) {
            flags.append(eventFlags[index])
        }
        watcher.handle(paths: paths, flags: flags)
    }
}
