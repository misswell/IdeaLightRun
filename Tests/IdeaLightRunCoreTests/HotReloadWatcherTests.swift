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

    func testRuntimeDisableStopsWatcherAndPublishesClosed() throws {
        let watcher = FakeWatcher(result: .started)
        let recorder = SessionRecorder()
        let session = makeSession(recorder: recorder) { _, _ in watcher }
        defer { session.stop() }
        session.start()
        XCTAssertNotNil(recorder.waitFor(timeout: 10) { $0.isWatching && $0.state == .listening })

        session.disable()

        let closed = recorder.waitFor(timeout: 10) { $0.state == .closed }
        XCTAssertNotNil(closed, "关闭后必须发布“热更新已关闭”：\(recorder.logs)")
        XCTAssertEqual(closed?.isWatching, false)
        XCTAssertFalse(closed?.canManualTrigger ?? true)
        XCTAssertNil(closed?.summary, "关闭后不能继续展示上一次“热更新成功”")
        XCTAssertEqual(watcher.stops, 1)
        XCTAssertTrue(closed?.detail.contains("Java 进程继续运行") == true)
        let states = recorder.all.map(\.state)
        XCTAssertTrue(states.contains(.disabling), "关闭过程必须先显示“正在关闭”：\(states)")
        XCTAssertEqual(states.last, .closed)

        // 关闭后不能在同一个运行实例上重新注入；必须重启应用。
        session.start()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(recorder.latest?.state, .closed)
        XCTAssertEqual(watcher.stops, 1)
    }

    func testRuntimeDisableDuringCompileAbortsBuildWithoutPublishingResult() throws {
        let watcher = FakeWatcher(result: .started)
        let adapter = BlockingBuildAdapter()
        let recorder = SessionRecorder()
        let session = makeSession(
            recorder: recorder,
            autoCompile: true,
            adapter: adapter
        ) { _, _ in watcher }
        defer { session.stop() }
        session.start()
        XCTAssertNotNil(recorder.waitFor(timeout: 10) { $0.isWatching && $0.state == .listening })

        try writeSource("class App { int compiling; }")
        session.requestManualReload()
        wait(for: [adapter.started], timeout: 10)
        XCTAssertEqual(recorder.latest?.state, .compiling)

        session.disable()
        wait(for: [adapter.cancelled], timeout: 10)

        let closed = recorder.waitFor(timeout: 10) { $0.state == .closed }
        XCTAssertNotNil(closed, "编译期间关闭也必须收敛到已关闭：\(recorder.logs)")
        XCTAssertEqual(adapter.buildCount, 1, "关闭后不得再发起新的编译")
        XCTAssertTrue(adapter.sawCancellation, "关闭必须终止正在进行的构建")
        XCTAssertFalse(
            recorder.all.contains { $0.state == .succeeded },
            "关闭期间不能把在途编译报成热更新成功：\(recorder.all.map(\.state))"
        )
        XCTAssertEqual(recorder.latest?.state, .closed)
    }

    func testCompoundMemberDisableOnlyClosesThatMember() throws {
        let workspace = makeWorkspace()

        func memberPlan(_ name: String) -> ExecutableLaunchPlan {
            let configuration = HotReloadConfiguration(
                enabled: true,
                provider: .springBootDevTools,
                autoCompileOnChange: false,
                watchCompiledOutputs: true,
                debounceMilliseconds: 200
            )
            let hotReload = HotReloadLaunchPlan(
                configuration: configuration,
                configName: name,
                provider: .springBootDevTools,
                capability: HotReloadProviderKind.springBootDevTools.staticCapability,
                workspace: workspace,
                adapter: StubBuildAdapter(),
                projectKey: projectRoot.path
            )
            return ExecutableLaunchPlan(
                executable: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: [:],
                workingDirectory: projectRoot,
                hotReload: hotReload
            )
        }

        let runtime = try ExecutionRuntime(
            configKey: "compound::All",
            configName: "All",
            execution: .compound(CompoundExecutionPlan(name: "All", members: [
                CompoundMemberPlan(
                    name: "Alpha",
                    configurationKey: "springBoot::Alpha",
                    execution: .process(memberPlan("Alpha"))
                ),
                CompoundMemberPlan(
                    name: "Beta",
                    configurationKey: "springBoot::Beta",
                    execution: .process(memberPlan("Beta"))
                ),
            ]))
        )
        let lock = NSLock()
        var events: [(String, HotReloadState)] = []
        runtime.setHandlers(onCompoundMember: { event in
            if case .hotReload(let snapshot) = event.kind {
                lock.lock()
                events.append((event.memberName, snapshot.state))
                lock.unlock()
            }
        })

        runtime.members[0].disableHotReload()

        XCTAssertEqual(runtime.members[0].hotReloadSnapshot?.state, .closed)
        XCTAssertEqual(runtime.members[1].hotReloadSnapshot?.state, .listening,
                       "关闭一个成员不能影响其它成员")

        lock.lock()
        let recorded = events
        lock.unlock()
        XCTAssertTrue(recorded.contains { $0.0 == "Alpha" && $0.1 == .closed }, "\(recorded)")
        XCTAssertFalse(recorded.contains { $0.0 == "Beta" }, "\(recorded)")
    }

    func testExecutionRuntimeStartsWithEnabledPlanAndDisableKeepsProcessAlive() throws {
        let configuration = HotReloadConfiguration(
            enabled: true,
            provider: .springBootDevTools,
            autoCompileOnChange: false,
            watchCompiledOutputs: false,
            debounceMilliseconds: 200
        )
        let hotReload = HotReloadLaunchPlan(
            configuration: configuration,
            configName: "Sleepy",
            provider: .springBootDevTools,
            capability: HotReloadProviderKind.springBootDevTools.staticCapability,
            workspace: makeWorkspace(),
            adapter: StubBuildAdapter(),
            projectKey: projectRoot.path
        )
        let runtime = try ExecutionRuntime(
            configKey: "springBoot::Sleepy",
            configName: "Sleepy",
            execution: .process(ExecutableLaunchPlan(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["100"],
                environment: [:],
                workingDirectory: projectRoot,
                hotReload: hotReload
            ))
        )
        let recorder = SessionRecorder()
        runtime.setHandlers(onHotReload: { recorder.record($0) })

        runtime.start()
        XCTAssertNotNil(recorder.waitFor(timeout: 10) { $0.state == .listening })
        XCTAssertTrue(runtime.isRunning)

        runtime.disableHotReload()
        XCTAssertNotNil(recorder.waitFor(timeout: 10) { $0.state == .closed })
        XCTAssertEqual(runtime.hotReloadSnapshot?.state, .closed)
        XCTAssertTrue(runtime.isRunning, "关闭热更新不能终止 Java 进程")

        runtime.stop()
        XCTAssertTrue(runtime.waitUntilExit(timeout: 5))
    }

    func testNewSessionCanListenAfterPreviousWasClosed() throws {
        let firstRecorder = SessionRecorder()
        let first = makeSession(recorder: firstRecorder) { _, _ in FakeWatcher(result: .started) }
        first.start()
        XCTAssertNotNil(firstRecorder.waitFor(timeout: 10) { $0.isWatching && $0.state == .listening })
        first.disable()
        XCTAssertEqual(first.currentSnapshot.state, .closed)
        first.stop()

        // 关闭只对当前 JVM 生效；重启后的新会话必须能重新监听。
        let recorder = SessionRecorder()
        let second = makeSession(recorder: recorder) { _, _ in FakeWatcher(result: .started) }
        defer { second.stop() }
        second.start()
        XCTAssertNotNil(
            recorder.waitFor(timeout: 10) { $0.isWatching && $0.state == .listening },
            "重启后的新实例应能重新建立监听：\(recorder.logs)"
        )
    }

    // MARK: - 脚手架

    private func makeWorkspace() -> HotReloadWorkspace {
        let module = ProjectModule(name: "demo", directory: projectRoot)
        let target = BuildTarget(
            module: module,
            variant: .maven(module: "demo", includeProvided: false)
        )
        return HotReloadWorkspace(
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
    }

    private func makeSession(
        recorder: SessionRecorder,
        autoCompile: Bool = false,
        adapter: any BuildSystemAdapter = StubBuildAdapter(),
        makeWatcher: @escaping @Sendable (
            HotReloadWorkspace,
            @escaping @Sendable ([String]) -> Void
        ) -> any HotReloadFileWatching
    ) -> HotReloadSession {
        let workspace = makeWorkspace()
        let configuration = HotReloadConfiguration(
            enabled: true,
            provider: .springBootDevTools,
            autoCompileOnChange: autoCompile,
            watchCompiledOutputs: true,
            debounceMilliseconds: 200
        )
        let plan = HotReloadLaunchPlan(
            configuration: configuration,
            configName: "Demo",
            provider: .springBootDevTools,
            capability: HotReloadProviderKind.springBootDevTools.staticCapability,
            workspace: workspace,
            adapter: adapter,
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
    private let lock = NSLock()
    private var stopCount = 0

    init(result: HotReloadWatcherStartResult) {
        self.result = result
    }

    var stops: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCount
    }

    func start() -> HotReloadWatcherStartResult { result }

    func stop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
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

    var all: [HotReloadSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
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

/// 只用于“编译过程中关闭”的测试：构建会一直阻塞到 ProcessHandle 被取消。
private final class BlockingBuildAdapter: BuildSystemAdapter, @unchecked Sendable {
    let started = XCTestExpectation(description: "开始编译")
    let cancelled = XCTestExpectation(description: "构建收到取消")
    private let lock = NSLock()
    private var count = 0
    private var cancellation = false

    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var sawCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellation
    }

    func classpathVariant(for module: ProjectModule, includeProvided: Bool) -> ClasspathVariant {
        .maven(module: module.name, includeProvided: includeProvided)
    }

    func buildModule(
        _ target: BuildTarget,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        lock.lock()
        count += 1
        let isFirst = count == 1
        lock.unlock()
        if isFirst { started.fulfill() }

        while handle?.isCancelled != true {
            Thread.sleep(forTimeInterval: 0.005)
        }
        lock.lock()
        cancellation = true
        lock.unlock()
        cancelled.fulfill()
        throw IdeaLightRunError.launchCancelled(detail: "热更新已关闭。")
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
