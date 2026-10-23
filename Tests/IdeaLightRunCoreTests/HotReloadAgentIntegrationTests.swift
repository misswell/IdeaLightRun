import Darwin
import Foundation
import XCTest
@testable import IdeaLightRunCore

/// 真实 JVM 验证：源码保存 → javac 增量编译 → 内置 Agent redefineClasses →
/// 运行中的进程输出改变；结构变更必须被 JVM 拒绝并标为“需要重启”。
/// 没有 JDK 的机器跳过，不伪造 Agent 行为。
final class HotReloadAgentIntegrationTests: XCTestCase {
    private var javaHome: URL!
    private var workRoot: URL!
    private var agentJar: URL!

    override func setUpWithError() throws {
        guard let home = Self.locateJavaHome() else {
            throw XCTSkip("未找到可用的 JDK（javac/java），跳过真实 JVM 集成测试。")
        }
        javaHome = home
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightrun-agent-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        agentJar = try buildAgent()
    }

    override func tearDownWithError() throws {
        if let workRoot {
            try? FileManager.default.removeItem(at: workRoot)
        }
    }

    func testStandardAgentReplacesMethodBodyInRunningJVM() throws {
        let scenario = try makeScenario(value: "one")
        defer { scenario.stop() }
        scenario.session.start()

        let listening = scenario.recorder.waitFor(timeout: 30) {
            $0.state == .listening && $0.isWatching
        }
        XCTAssertNotNil(
            listening,
            "热更新会话未进入监听状态：\(scenario.diagnostics())"
        )

        try writeSource(value: "two")

        let outcome = scenario.recorder.waitFor(timeout: 40) {
            $0.summary != nil && !$0.state.isBusy && $0.state != .listening
        }
        XCTAssertEqual(
            outcome?.state,
            .succeeded,
            "方法体替换未成功：\(scenario.diagnostics())"
        )
        XCTAssertEqual(outcome?.summary?.appliedClasses, ["demo.App"])
        XCTAssertTrue(outcome?.summary?.didCompile == true)

        XCTAssertTrue(
            waitForOutput(containing: "VALUE=two", timeout: 15),
            "JVM 输出没有反映替换后的方法体：\(scenario.output())"
        )
    }

    func testStructuralChangeIsRejectedAndReportedAsRestart() throws {
        let scenario = try makeScenario(value: "one")
        defer { scenario.stop() }
        scenario.session.start()

        let listening = scenario.recorder.waitFor(timeout: 30) {
            $0.state == .listening && $0.isWatching
        }
        XCTAssertNotNil(
            listening,
            "热更新会话未进入监听状态：\(scenario.diagnostics())"
        )

        try writeSource(value: "one", extraField: true)

        let outcome = scenario.recorder.waitFor(timeout: 40) {
            $0.summary != nil && !$0.state.isBusy && $0.state != .listening
        }
        XCTAssertEqual(
            outcome?.state,
            .requiresRestart,
            "结构变更必须如实报告为需要重启：\(scenario.diagnostics())"
        )
        let failure = outcome?.summary?.failedClasses.first { $0.className == "demo.App" }
        XCTAssertEqual(failure?.kind, .schemaChange, "实际失败：\(failure?.message ?? "无")")
        XCTAssertEqual(outcome?.summary?.appliedClasses, [])
        XCTAssertTrue(scenario.process.isRunning, "redefine 失败不应杀死应用")
        XCTAssertFalse(
            scenario.output().contains("VALUE=two"),
            "结构变更被拒绝后不应出现部分应用的假象"
        )
    }

    // MARK: - 场景

    private func makeScenario(value: String) throws -> AgentScenario {
        let projectRoot = workRoot.appendingPathComponent("project", isDirectory: true)
        let sourceRoot = projectRoot.appendingPathComponent("src/main/java", isDirectory: true)
        let sourceURL = sourceRoot.appendingPathComponent("demo/App.java")
        let classesRoot = projectRoot.appendingPathComponent("target/classes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: classesRoot, withIntermediateDirectories: true)
        try writeSource(value: value)

        let adapter = JavacAdapter(sourceRoot: sourceRoot, outputRoot: classesRoot, javaHome: javaHome)
        try adapter.buildModule(
            BuildTarget(
                module: ProjectModule(name: "demo", directory: projectRoot, artifactId: "demo"),
                variant: .maven(module: "demo", includeProvided: false)
            ),
            handle: nil,
            log: { _ in }
        )

        let agentLaunch = try HotReloadAgentLaunch.prepare(jarURL: agentJar)
        let outputURL = workRoot.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = javaHome.appendingPathComponent("bin/java")
        process.arguments = agentLaunch.jvmArguments
            + ["-cp", classesRoot.path, "demo.App"]
        process.currentDirectoryURL = projectRoot
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()

        let module = ProjectModule(name: "demo", directory: projectRoot, artifactId: "demo")
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
            provider: .standard,
            autoCompileOnChange: true,
            watchCompiledOutputs: true,
            watchResources: true,
            restartPolicy: .notify,
            debounceMilliseconds: 200
        )
        let plan = HotReloadLaunchPlan(
            configuration: configuration,
            configName: "Demo",
            provider: .standard,
            capability: HotReloadProviderKind.standard.staticCapability,
            workspace: workspace,
            adapter: adapter,
            projectKey: projectRoot.standardizedFileURL.path,
            agentLaunch: agentLaunch
        )

        let recorder = SnapshotRecorder()
        let session = HotReloadSession(
            plan: plan,
            log: { line in recorder.recordLog(line) },
            onSnapshot: { snapshot in recorder.record(snapshot) }
        )
        return AgentScenario(
            process: process,
            outputHandle: outputHandle,
            outputURL: outputURL,
            agentLaunch: agentLaunch,
            recorder: recorder,
            session: session
        )
    }

    /// 改源码必须换一个 inode：原子写会让 FSEvents 产生明确的变更事件，
    /// 也避免同一秒内写入导致 mtime 复用旧指纹。
    private func writeSource(value: String, extraField: Bool = false) throws {
        let sourceURL = workRoot
            .appendingPathComponent("project/src/main/java/demo/App.java")
        let field = extraField ? "    static int extra = 0;\n" : ""
        let source = """
        package demo;

        public class App {
            static String value() { return "\(value)"; }
        \(field)
            public static void main(String[] args) throws Exception {
                while (true) {
                    System.out.println("VALUE=" + value());
                    System.out.flush();
                    Thread.sleep(100);
                }
            }
        }

        """
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
    }

    private func waitForOutput(containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if output().contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return output().contains(needle)
    }

    private func output() -> String {
        let url = workRoot.appendingPathComponent("app.log")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Agent 构建

    private func buildAgent() throws -> URL {
        let classes = workRoot.appendingPathComponent("agent-classes", isDirectory: true)
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("HotReloadAgent/src/main/java/com/misswell/idealightrun/agent/HotReloadAgent.java")
        let manifest = repoRoot.appendingPathComponent("HotReloadAgent/Manifest.txt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "缺少 Agent 源码：\(source.path)"
        )
        try Self.runTool(
            javaHome.appendingPathComponent("bin/javac"),
            ["-source", "8", "-target", "8", "-encoding", "UTF-8", "-d", classes.path, source.path],
            workingDirectory: workRoot
        )
        let jar = workRoot.appendingPathComponent("HotReloadAgent.jar")
        try Self.runTool(
            javaHome.appendingPathComponent("bin/jar"),
            ["cfm", jar.path, manifest.path, "-C", classes.path, "."],
            workingDirectory: workRoot
        )
        return jar
    }

    private static func locateJavaHome() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["JAVA_HOME"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        let bases = [
            "/Library/Java/JavaVirtualMachines",
            NSHomeDirectory() + "/Library/Java/JavaVirtualMachines"
        ]
        for base in bases {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for entry in entries.sorted().reversed() {
                candidates.append(
                    URL(fileURLWithPath: base)
                        .appendingPathComponent(entry)
                        .appendingPathComponent("Contents/Home")
                )
            }
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/opt/openjdk"))
        candidates.append(URL(fileURLWithPath: "/usr/local/opt/openjdk"))

        return candidates.first { home in
            isExecutable(home.appendingPathComponent("bin/javac"))
                && isExecutable(home.appendingPathComponent("bin/java"))
                && isExecutable(home.appendingPathComponent("bin/jar"))
        }
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    @discardableResult
    private static func runTool(
        _ executable: URL,
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "HotReloadAgentIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable.lastPathComponent) 失败（\(process.terminationStatus)）：\(output)"
                ]
            )
        }
        return output
    }
}

// MARK: - 测试脚手架

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [HotReloadSnapshot] = []
    private var logs: [String] = []

    func record(_ snapshot: HotReloadSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    func recordLog(_ line: String) {
        lock.lock()
        logs.append(line)
        lock.unlock()
    }

    var latest: HotReloadSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last
    }

    var allLogs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }

    func waitFor(
        timeout: TimeInterval,
        _ predicate: (HotReloadSnapshot) -> Bool
    ) -> HotReloadSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let latest, predicate(latest) {
                return latest
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let latest, predicate(latest) else { return nil }
        return latest
    }
}

private final class AgentScenario {
    let process: Process
    let outputHandle: FileHandle
    let outputURL: URL
    let agentLaunch: HotReloadAgentLaunch
    let recorder: SnapshotRecorder
    let session: HotReloadSession

    init(
        process: Process,
        outputHandle: FileHandle,
        outputURL: URL,
        agentLaunch: HotReloadAgentLaunch,
        recorder: SnapshotRecorder,
        session: HotReloadSession
    ) {
        self.process = process
        self.outputHandle = outputHandle
        self.outputURL = outputURL
        self.agentLaunch = agentLaunch
        self.recorder = recorder
        self.session = session
    }

    func stop() {
        session.stop()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        try? outputHandle.close()
        agentLaunch.cleanup()
    }

    func output() -> String {
        (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    }

    func diagnostics() -> String {
        let snapshot = recorder.latest
        let state = snapshot.map { "\($0.state.displayText) / \($0.detail)" } ?? "无快照"
        return """
        状态：\(state)
        日志：
        \(recorder.allLogs.suffix(20).joined(separator: "\n"))
        应用输出：
        \(output().suffix(2000))
        """
    }
}

/// 最小构建适配器：真实调用 javac 重新编译模块源码，模拟 Maven 的 buildModule。
private struct JavacAdapter: BuildSystemAdapter {
    let sourceRoot: URL
    let outputRoot: URL
    let javaHome: URL

    func classpathVariant(for module: ProjectModule, includeProvided: Bool) -> ClasspathVariant {
        .maven(module: module.artifactId ?? module.name, includeProvided: includeProvided)
    }

    func buildModule(
        _ target: BuildTarget,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        if handle?.isCancelled == true {
            throw IdeaLightRunError.launchCancelled(detail: "构建已取消。")
        }
        let sources = try collectSources()
        guard !sources.isEmpty else { return }
        let process = Process()
        process.executableURL = javaHome.appendingPathComponent("bin/javac")
        process.arguments = ["-encoding", "UTF-8", "-d", outputRoot.path] + sources
        process.currentDirectoryURL = sourceRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        handle?.attach(process)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        handle?.detach()
        let text = String(decoding: data, as: UTF8.self)
        if !text.isEmpty {
            log(LogLine(stream: .stdout, text: text))
        }
        guard process.terminationStatus == 0 else {
            throw IdeaLightRunError.buildFailed(
                detail: "javac 退出码 \(process.terminationStatus)：\(text)"
            )
        }
    }

    func buildProject(
        kind: ProjectBuildKind,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        throw IdeaLightRunError.unsupportedConfiguration(detail: "测试适配器不支持整个项目构建。")
    }

    func runTasks(
        _ tasks: [String],
        pomFile: String?,
        moduleDirectory: URL,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws {
        throw IdeaLightRunError.unsupportedConfiguration(detail: "测试适配器不支持构建任务。")
    }

    func hasFreshClasspathCache(for target: BuildTarget) -> Bool { true }

    func runtimeClasspath(
        _ target: BuildTarget,
        withBuild: Bool,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws -> [String] {
        [outputRoot.path]
    }

    func testExecution(
        _ config: RunConfiguration,
        module: ProjectModule,
        context: BuildInvocationContext,
        log: @escaping LogCallback
    ) throws -> TestExecutionPlan {
        throw IdeaLightRunError.unsupportedConfiguration(detail: "测试适配器不支持测试执行。")
    }

    private func collectSources() throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "java" {
            result.append(url.path)
        }
        return result.sorted()
    }
}
