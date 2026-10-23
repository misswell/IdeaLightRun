import XCTest
@testable import IdeaLightRunCore

/// 监听器启动失败必须可见、可重试；建立基准与启动监听之间发生的保存不能永久丢失。
final class HotReloadWatcherTests: XCTestCase {
    private var projectRoot: URL!
    private var sourceRoot: URL!
    private var classesRoot: URL!

    override func setUpWithError() throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hot-reload-watcher-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = projectRoot.appendingPathComponent("src/main/java", isDirectory: true)
        classesRoot = projectRoot.appendingPathComponent("target/classes", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: classesRoot, withIntermediateDirectories: true)
        try Data("class App {}".utf8).write(
            to: sourceRoot.appendingPathComponent("demo/App.java").existsCreatingParent()
        )
        let root = projectRoot!
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testCreateFailureIsReportedAndNothingStaysRunning() {
        let backend = BackendProbe(createResult: nil)
        let watcher = HotReloadFileWatcher(
            roots: [projectRoot],
            isRelevant: { _ in true },
            onEvents: { _ in },
            backend: backend.backend
        )
        XCTAssertEqual(watcher.start(), .createFailed)
        XCTAssertEqual(backend.startCalls, 0)
        XCTAssertEqual(backend.invalidateCalls, 0)
    }

    func testStartFailureReleasesStreamAndReportsReason() {
        let backend = BackendProbe(startResult: false)
        let watcher = HotReloadFileWatcher(
            roots: [projectRoot],
            isRelevant: { _ in true },
            onEvents: { _ in },
            backend: backend.backend
        )
        let result = watcher.start()
        XCTAssertEqual(result, .startFailed)
        XCTAssertNotNil(result.failureReason)
        XCTAssertEqual(backend.startCalls, 1)
        XCTAssertEqual(backend.invalidateCalls, 1)
        XCTAssertEqual(backend.releaseCalls, 1)
    }

    func testSuccessfulStartThenStopReleasesExactlyOnce() {
        let backend = BackendProbe()
        let watcher = HotReloadFileWatcher(
            roots: [projectRoot],
            isRelevant: { _ in true },
            onEvents: { _ in },
            backend: backend.backend
        )
        XCTAssertEqual(watcher.start(), .started)
        XCTAssertEqual(watcher.start(), .alreadyStarted)
        watcher.stop()
        XCTAssertEqual(backend.stopCalls, 1)
        XCTAssertEqual(backend.invalidateCalls, 1)
        XCTAssertEqual(backend.releaseCalls, 1)
        XCTAssertEqual(watcher.start(), .stopped)
    }

    func testSessionShowsWatcherFailureAndRetryCatchesMissedChange() throws {
        let first = FakeWatcher(result: .createFailed)
        let second = FakeWatcher(result: .started)
        let calls = Counter()
        let recorder = SessionRecorder()
        let session = makeSession(recorder: recorder) { _, _ in
            calls.next() == 1 ? first : second
        }
        defer { session.stop() }
        session.start()

        let failed = recorder.waitFor(timeout: 10) {
            $0.state == .watcherUnavailable
        }
        XCTAssertNotNil(failed, "监听启动失败必须上报，不能显示为监听中：\(recorder.logs)")
        XCTAssertEqual(failed?.isWatching, false)
        XCTAssertEqual(failed?.canRetryWatcher, true)
        XCTAssertTrue(failed?.detail.contains("FSEventStream") == true)

        // 失败期间保存的源码：重试成功后的对账必须发现它。
        try writeSource("class App { int changed; }")
        session.retryWatcher()

        let recovered = recorder.waitFor(timeout: 10) {
            $0.isWatching && $0.state == .attention
        }
        XCTAssertNotNil(
            recovered,
            "重试监听后应恢复监听并补处理失败期间的变更：\(recorder.logs)"
        )
        XCTAssertTrue(
            recorder.logs.contains { $0.contains("对账发现") },
            "缺少启动后对账日志：\(recorder.logs)"
        )
    }

    func testChangeDuringWatcherStartIsReconciled() throws {
        let recorder = SessionRecorder()
        let sourceURL = sourceRoot.appendingPathComponent("demo/App.java")
        let session = makeSession(recorder: recorder) { _, _ in
            // 模拟“基准快照已完成、FSEventStream 尚未就绪”窗口内的保存。
            try? Data("class App { int duringStart; }".utf8)
                .write(to: sourceURL, options: .atomic)
            return FakeWatcher(result: .started)
        }
        defer { session.stop() }
        session.start()

        let reconciled = recorder.waitFor(timeout: 10) {
            $0.state == .attention && $0.isWatching
        }
        XCTAssertNotNil(
            reconciled,
            "初始化窗口内的保存必须通过对账被发现：\(recorder.logs)"
        )
        XCTAssertTrue(recorder.logs.contains { $0.contains("对账发现") })
    }

    // MARK: - 脚手架

    private func makeSession(
        recorder: SessionRecorder,
        makeWatcher: @escaping @Sendable (
            HotReloadWorkspace,
            @escaping @Sendable ([String]) -> Void
        ) -> any HotReloadFileWatching
    ) -> HotReloadSession {
        let module = ProjectModule(name: "demo", directory: projectRoot)
        let target = BuildTarget(
            module: module,
            variant: .maven(module: "demo", includeProvided: false)
        )
        let workspace = HotReloadWorkspace(
            projectRoot: projectRoot.standardizedFileURL,
            primaryModule: module,
            primaryTarget: target,
            moduleWatches: [
                HotReloadModuleWatch(
                    module: module,
                    target: target,
                    codeRoots: [sourceRoot],
                    resourceRoots: []
                )
            ],
            outputRoots: [classesRoot]
        )
        let configuration = HotReloadConfiguration(
            enabled: true,
            provider: .springBootDevTools,
            autoCompileOnChange: false,
            watchCompiledOutputs: true,
            debounceMilliseconds: 200
        )
        let plan = HotReloadLaunchPlan(
            configuration: configuration,
            configName: "Demo",
            provider: .springBootDevTools,
            capability: HotReloadProviderKind.springBootDevTools.staticCapability,
            workspace: workspace,
            adapter: StubBuildAdapter(),
            projectKey: projectRoot.path
        )
        return HotReloadSession(
            plan: plan,
            log: { recorder.recordLog($0) },
            onSnapshot: { recorder.record($0) },
            makeWatcher: makeWatcher
        )
    }

    private func writeSource(_ contents: String) throws {
        let url = sourceRoot.appendingPathComponent("demo/App.java")
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}

private extension URL {
    func existsCreatingParent() -> URL {
        try? FileManager.default.createDirectory(
            at: deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return self
    }
}

private final class BackendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let createResult: AnyObject?
    private let startResult: Bool
    private var created: AnyObject?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var invalidateCalls = 0
    private(set) var releaseCalls = 0

    init(createResult: AnyObject? = NSObject(), startResult: Bool = true) {
        self.createResult = createResult
        self.startResult = startResult
    }

    var backend: HotReloadFSEventStreamBackend {
        HotReloadFSEventStreamBackend(
            create: { [self] _, _, _, _ in
                lock.lock()
                defer { lock.unlock() }
                created = createResult
                return createResult
            },
            setQueue: { _, _ in },
            start: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                startCalls += 1
                return startResult
            },
            stop: { [self] _ in
                lock.lock()
                stopCalls += 1
                lock.unlock()
            },
            invalidate: { [self] _ in
                lock.lock()
                invalidateCalls += 1
                lock.unlock()
            },
            release: { [self] _ in
                lock.lock()
                releaseCalls += 1
                lock.unlock()
            }
        )
    }
}

private final class FakeWatcher: HotReloadFileWatching, @unchecked Sendable {
    private let result: HotReloadWatcherStartResult

    init(result: HotReloadWatcherStartResult) {
        self.result = result
    }

    func start() -> HotReloadWatcherStartResult { result }
    func stop() {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class SessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [HotReloadSnapshot] = []
    private var lines: [String] = []

    func record(_ snapshot: HotReloadSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    func recordLog(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var latest: HotReloadSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last
    }

    var logs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func waitFor(
        timeout: TimeInterval,
        _ predicate: (HotReloadSnapshot) -> Bool
    ) -> HotReloadSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let latest, predicate(latest) { return latest }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let latest, predicate(latest) else { return nil }
        return latest
    }
}

private struct StubBuildAdapter: BuildSystemAdapter {
    func classpathVariant(for module: ProjectModule, includeProvided: Bool) -> ClasspathVariant {
        .maven(module: module.name, includeProvided: includeProvided)
    }

    func buildModule(
        _ target: BuildTarget,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        XCTFail("自动编译关闭时不应调用构建")
    }

    func buildProject(
        kind: ProjectBuildKind,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        throw IdeaLightRunError.unsupportedConfiguration(detail: "测试不构建项目")
    }

    func runTasks(
        _ tasks: [String],
        pomFile: String?,
        moduleDirectory: URL,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        throw IdeaLightRunError.unsupportedConfiguration(detail: "测试不运行构建任务")
    }

    func hasFreshClasspathCache(for target: BuildTarget) -> Bool { true }

    func runtimeClasspath(
        _ target: BuildTarget,
        withBuild: Bool,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws -> [String] {
        []
    }

    func testExecution(
        _ config: RunConfiguration,
        module: ProjectModule,
        context: BuildInvocationContext,
        log: @escaping LogCallback
    ) throws -> TestExecutionPlan {
        throw IdeaLightRunError.unsupportedConfiguration(detail: "测试不支持 JUnit")
    }
}
