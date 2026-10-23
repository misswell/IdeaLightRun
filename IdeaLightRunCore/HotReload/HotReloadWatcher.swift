import CoreServices
import Foundation

/// 监听器启动结果。只有 `.started` / `.alreadyStarted` 才允许对外显示“监听中”；
/// 创建或启动 FSEventStream 失败时必须把原因带回会话，不能静默当作已监听。
public enum HotReloadWatcherStartResult: Equatable, Sendable {
    case started
    case alreadyStarted
    case stopped
    case noRoots
    case createFailed
    case startFailed

    public var isSuccess: Bool {
        self == .started || self == .alreadyStarted
    }

    public var failureReason: String? {
        switch self {
        case .started, .alreadyStarted:
            return nil
        case .stopped:
            return "监听器已停止，无法重新启动。"
        case .noRoots:
            return "没有可监听的目录。"
        case .createFailed:
            return "无法创建 FSEventStream（路径不可访问或系统资源不足）。"
        case .startFailed:
            return "FSEventStreamStart 失败（监听目录不可访问或系统拒绝监听）。"
        }
    }
}

/// 会话只依赖这个最小接口，测试可以注入启动失败 / 启动成功的假实现。
protocol HotReloadFileWatching: AnyObject, Sendable {
    func start() -> HotReloadWatcherStartResult
    func stop()
}

/// FSEvents 的 C API 无法在测试里真实制造失败，抽出薄后端供测试注入。
struct HotReloadFSEventStreamBackend: Sendable {
    var create: @Sendable (UnsafeMutablePointer<FSEventStreamContext>, [String], TimeInterval, UInt32) -> AnyObject?
    var setQueue: @Sendable (AnyObject, DispatchQueue) -> Void
    var start: @Sendable (AnyObject) -> Bool
    var stop: @Sendable (AnyObject) -> Void
    var invalidate: @Sendable (AnyObject) -> Void
    var release: @Sendable (AnyObject) -> Void

    static let system = HotReloadFSEventStreamBackend(
        create: { context, roots, latency, flags in
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                HotReloadFileWatcher.callback,
                context,
                roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                return nil
            }
            return HotReloadFSEventStreamHandle(created)
        },
        setQueue: { stream, queue in
            guard let handle = stream as? HotReloadFSEventStreamHandle else { return }
            FSEventStreamSetDispatchQueue(handle.ref, queue)
        },
        start: { stream in
            guard let handle = stream as? HotReloadFSEventStreamHandle else { return false }
            return FSEventStreamStart(handle.ref)
        },
        stop: { stream in
            guard let handle = stream as? HotReloadFSEventStreamHandle else { return }
            FSEventStreamStop(handle.ref)
        },
        invalidate: { stream in
            guard let handle = stream as? HotReloadFSEventStreamHandle else { return }
            FSEventStreamInvalidate(handle.ref)
        },
        release: { stream in
            guard let handle = stream as? HotReloadFSEventStreamHandle else { return }
            FSEventStreamRelease(handle.ref)
        }
    )
}

private final class HotReloadFSEventStreamHandle {
    let ref: FSEventStreamRef

    init(_ ref: FSEventStreamRef) {
        self.ref = ref
    }
}

/// FSEvents 只作为“可能有变化”的信号：真正的变更由会话重新快照并做指纹 diff。
/// 这样自己编译产生的输出、外部 IDEA 构建、编辑器原子保存不会重复触发同一批变更。
public final class HotReloadFileWatcher: HotReloadFileWatching, @unchecked Sendable {
    private let roots: [String]
    private let latency: TimeInterval
    private let isRelevant: @Sendable (String) -> Bool
    private let onEvents: @Sendable ([String]) -> Void
    private let backend: HotReloadFSEventStreamBackend
    private let queue = DispatchQueue(label: "com.misswell.IdeaLightRun.hot-reload-fsevents", qos: .utility)

    private let lock = NSLock()
    private var stream: AnyObject?
    private var stopped = false

    public convenience init(
        roots: [URL],
        latency: TimeInterval = 0.15,
        isRelevant: @escaping @Sendable (String) -> Bool,
        onEvents: @escaping @Sendable ([String]) -> Void
    ) {
        self.init(
            roots: roots,
            latency: latency,
            isRelevant: isRelevant,
            onEvents: onEvents,
            backend: .system
        )
    }

    init(
        roots: [URL],
        latency: TimeInterval = 0.15,
        isRelevant: @escaping @Sendable (String) -> Bool,
        onEvents: @escaping @Sendable ([String]) -> Void,
        backend: HotReloadFSEventStreamBackend
    ) {
        self.roots = roots.map { $0.standardizedFileURL.path }
        self.latency = max(0.05, latency)
        self.isRelevant = isRelevant
        self.onEvents = onEvents
        self.backend = backend
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> HotReloadWatcherStartResult {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return .stopped
        }
        guard stream == nil else {
            lock.unlock()
            return .alreadyStarted
        }
        guard !roots.isEmpty else {
            lock.unlock()
            return .noRoots
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
        guard let created = backend.create(&context, roots, latency, flags) else {
            lock.unlock()
            return .createFailed
        }
        backend.setQueue(created, queue)
        guard backend.start(created) else {
            backend.invalidate(created)
            backend.release(created)
            lock.unlock()
            return .startFailed
        }
        stream = created
        lock.unlock()
        return .started
    }

    public func stop() {
        lock.lock()
        stopped = true
        let existing = stream
        stream = nil
        lock.unlock()
        guard let existing else { return }
        backend.stop(existing)
        backend.invalidate(existing)
        backend.release(existing)
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

    fileprivate static let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
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
