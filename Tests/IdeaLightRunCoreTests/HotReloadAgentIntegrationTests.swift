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

    func testMultipleClassesAreRedefinedInOneAtomicGroup() throws {
        let scenario = try makePairScenario(a: "a1", b: "b1")
        defer { scenario.stop() }
        scenario.session.start()

        XCTAssertNotNil(
            scenario.recorder.waitFor(timeout: 30) { $0.state == .listening && $0.isWatching },
            "热更新会话未进入监听状态：\(scenario.diagnostics())"
        )

        try writePairSources(a: "a2", b: "b2")

        let outcome = scenario.recorder.waitFor(timeout: 40) {
            $0.summary != nil && !$0.state.isBusy && $0.state != .listening
        }
        XCTAssertEqual(outcome?.state, .succeeded, "两方法体应同组替换成功：\(scenario.diagnostics())")
        XCTAssertEqual(outcome?.summary?.appliedClasses, ["demo.A", "demo.B"])
        XCTAssertTrue(
            waitForOutput(containing: "PAIR=a2:b2", timeout: 15),
            "两个类的方法体都必须生效：\(scenario.output())"
        )
    }

    func testStructuralFailureLeavesWholeGroupUnapplied() throws {
        // App 同时调用 A 与 B：先改 A 的方法体，再让 B 增加字段。
        // 如果按类逐个 redefine，会出现 A 已替换、B 失败的半更新状态。
        let scenario = try makePairScenario(a: "a1", b: "b1")
        defer { scenario.stop() }
        scenario.session.start()

        XCTAssertNotNil(
            scenario.recorder.waitFor(timeout: 30) { $0.state == .listening && $0.isWatching },
            "热更新会话未进入监听状态：\(scenario.diagnostics())"
        )

        try writePairSources(a: "a2", b: "b1", addFieldToB: true)

        let outcome = scenario.recorder.waitFor(timeout: 40) {
            $0.summary != nil && !$0.state.isBusy && $0.state != .listening
        }
        XCTAssertEqual(
            outcome?.state,
            .requiresRestart,
            "整组被拒后必须报告需要重启：\(scenario.diagnostics())"
        )
        XCTAssertEqual(outcome?.summary?.appliedClasses, [])
        let failures = outcome?.summary?.failedClasses ?? []
        XCTAssertEqual(Set(failures.map(\.className)), ["demo.A", "demo.B"])
        XCTAssertTrue(
            failures.allSatisfy { $0.kind == .atomicGroupAborted },
            "整组拒绝必须如实标注：\(failures.map { "\($0.className)=\($0.kind)" })"
        )
        XCTAssertTrue(scenario.process.isRunning, "redefine 失败不应杀死应用")
        XCTAssertFalse(
            scenario.output().contains("PAIR=a2"),
            "组内结构失败时 A 也不能被单独应用：\(scenario.output())"
        )
        XCTAssertTrue(waitForOutput(containing: "PAIR=a1:b1", timeout: 5))
    }

    func testSameNameClassMatchesLoadedCopyByCodeSource() async throws {
        let projectRoot = workRoot.appendingPathComponent("loader-project", isDirectory: true)
        let appSources = projectRoot.appendingPathComponent("app-src", isDirectory: true)
        let appClasses = projectRoot.appendingPathComponent("app-classes", isDirectory: true)
        let leftDir = projectRoot.appendingPathComponent("left", isDirectory: true)
        let rightDir = projectRoot.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)

        try compilePlugin(value: "left1", into: leftDir)
        try compilePlugin(value: "right1", into: rightDir)
        try writeLoaderApp(to: appSources)
        try FileManager.default.createDirectory(at: appClasses, withIntermediateDirectories: true)
        try Self.runTool(
            javaHome.appendingPathComponent("bin/javac"),
            [
                "-encoding", "UTF-8", "-d", appClasses.path,
                appSources.appendingPathComponent("demo/LoaderApp.java").path
            ],
            workingDirectory: projectRoot
        )

        let agentLaunch = try HotReloadAgentLaunch.prepare(jarURL: agentJar)
        let outputURL = projectRoot.appendingPathComponent("loader.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = javaHome.appendingPathComponent("bin/java")
        process.arguments = agentLaunch.jvmArguments + [
            "-cp", appClasses.path,
            "demo.LoaderApp", leftDir.path, rightDir.path
        ]
        process.currentDirectoryURL = projectRoot
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        defer {
            terminate(process)
            try? outputHandle.close()
            agentLaunch.cleanup()
        }

        XCTAssertTrue(
            waitForLog(at: outputURL, containing: "COPIES=left1:right1", timeout: 20),
            "两个 ClassLoader 未按预期加载同名类"
        )
        try compilePlugin(value: "right2", into: rightDir)

        let port = try await HotReloadAgentEndpoint.waitForPort(
            portFile: agentLaunch.portFileURL,
            timeout: 20
        )
        let client = try HotReloadAgentClient(port: port, token: agentLaunch.token)
        defer { client.shutdown() }

        let rightClassFile = rightDir.appendingPathComponent("dupe/Plugin.class")
        let applied = try client.reload(classes: [(
            name: "dupe.Plugin",
            path: rightClassFile.path,
            origin: rightDir.path
        )])
        XCTAssertEqual(applied.status, .ok, "实际响应：\(applied.message)")
        XCTAssertEqual(applied.classes.first?.filePath, rightClassFile.path)
        XCTAssertTrue(
            waitForLog(at: outputURL, containing: "COPIES=left1:right2", timeout: 15),
            "只有来源匹配的那份副本应被替换：\(readLog(at: outputURL))"
        )

        // 输出目录匹配不到任何已加载副本：必须拒绝，不能退回“取第一个”。
        let wrongOrigin = projectRoot.appendingPathComponent("not-a-source", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongOrigin, withIntermediateDirectories: true)
        let mismatch = try client.reload(classes: [(
            name: "dupe.Plugin",
            path: rightClassFile.path,
            origin: wrongOrigin.path
        )])
        XCTAssertEqual(mismatch.status, .partial)
        let mismatchResult = try XCTUnwrap(mismatch.classes.first)
        XCTAssertTrue(mismatchResult.message.contains("origin mismatch"))
        XCTAssertEqual(HotReloadFailureKind.classify(mismatchResult.message), .classOriginMismatch)

        // 无法从路径推导输出来源、且存在两份副本：必须返回歧义错误。
        let ambiguous = try client.reload(classes: [(
            name: "dupe.Plugin",
            path: rightDir.appendingPathComponent("dupe/Plugin.class.bin").path,
            origin: ""
        )])
        XCTAssertEqual(ambiguous.status, .partial)
        let ambiguousResult = try XCTUnwrap(ambiguous.classes.first)
        XCTAssertTrue(ambiguousResult.message.contains("ambiguous"))
        XCTAssertEqual(HotReloadFailureKind.classify(ambiguousResult.message), .ambiguousClass)
        XCTAssertTrue(
            readLog(at: outputURL).contains("COPIES=left1:right2"),
            "被拒绝的请求不能改动任何副本"
        )
    }

    // MARK: - 场景

    private func compilePlugin(value: String, into output: URL) throws {
        let sourceRoot = projectRootForPlugin(value: value)
        try Self.runTool(
            javaHome.appendingPathComponent("bin/javac"),
            [
                "-encoding", "UTF-8", "-d", output.path,
                sourceRoot.appendingPathComponent("dupe/Plugin.java").path
            ],
            workingDirectory: sourceRoot
        )
    }

    private func projectRootForPlugin(value: String) -> URL {
        let root = workRoot.appendingPathComponent("plugin-\(value)", isDirectory: true)
        let source = root.appendingPathComponent("dupe/Plugin.java")
        try? FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = """
        package dupe;

        public class Plugin {
            public static String value() { return "\(value)"; }
        }

        """
        try? Data(contents.utf8).write(to: source)
        return root
    }

    private func writeLoaderApp(to sourceRoot: URL) throws {
        let url = sourceRoot.appendingPathComponent("demo/LoaderApp.java")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = """
        package demo;

        import java.io.File;
        import java.lang.reflect.Method;
        import java.net.URL;
        import java.net.URLClassLoader;

        public class LoaderApp {
            public static void main(String[] args) throws Exception {
                URLClassLoader left = new URLClassLoader(
                    new URL[] { new File(args[0]).toURI().toURL() },
                    null
                );
                URLClassLoader right = new URLClassLoader(
                    new URL[] { new File(args[1]).toURI().toURL() },
                    null
                );
                Method leftValue = left.loadClass("dupe.Plugin").getMethod("value");
                Method rightValue = right.loadClass("dupe.Plugin").getMethod("value");
                while (true) {
                    System.out.println(
                        "COPIES=" + leftValue.invoke(null) + ":" + rightValue.invoke(null)
                    );
                    System.out.flush();
                    Thread.sleep(100);
                }
            }
        }

        """
        try Data(contents.utf8).write(to: url)
    }

    private func waitForLog(at url: URL, containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readLog(at: url).contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return readLog(at: url).contains(needle)
    }

    private func readLog(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 同步收尾；异步测试的 defer 不能 await，把等待封在同步函数里也避免 noasync 告警。
    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func makeScenario(value: String) throws -> AgentScenario {
        try startScenario(
            sources: ["demo/App.java": singleClassSource(value: value)],
            mainClass: "demo.App"
        )
    }

    private func makePairScenario(a: String, b: String) throws -> AgentScenario {
        try startScenario(
            sources: [
                "demo/App.java": pairAppSource,
                "demo/A.java": pairClassSource(name: "A", value: a),
                "demo/B.java": pairClassSource(name: "B", value: b)
            ],
            mainClass: "demo.App"
        )
    }

    private func startScenario(
        sources: [String: String],
        mainClass: String
    ) throws -> AgentScenario {
        let projectRoot = workRoot.appendingPathComponent("project", isDirectory: true)
        let sourceRoot = projectRoot.appendingPathComponent("src/main/java", isDirectory: true)
        let classesRoot = projectRoot.appendingPathComponent("target/classes", isDirectory: true)
        for (relative, contents) in sources {
            let url = sourceRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url, options: .atomic)
        }
        try FileManager.default.createDirectory(at: classesRoot, withIntermediateDirectories: true)

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
            + ["-cp", classesRoot.path, mainClass]
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

    private func singleClassSource(value: String, extraField: Bool = false) -> String {
        let field = extraField ? "    static int extra = 0;\n" : ""
        return """
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
    }

    private var pairAppSource: String {
        """
        package demo;

        public class App {
            public static void main(String[] args) throws Exception {
                while (true) {
                    System.out.println("PAIR=" + A.value() + ":" + B.value());
                    System.out.flush();
                    Thread.sleep(100);
                }
            }
        }

        """
    }

    private func pairClassSource(name: String, value: String, extraField: Bool = false) -> String {
        let field = extraField ? "    static int extra = 0;\n" : ""
        return """
        package demo;

        public class \(name) {
        \(field)
            public static String value() { return "\(value)"; }
        }

        """
    }

    private func writePairSources(a: String, b: String, addFieldToB: Bool = false) throws {
        try writePairFile("demo/A.java", pairClassSource(name: "A", value: a))
        try writePairFile(
            "demo/B.java",
            pairClassSource(name: "B", value: b, extraField: addFieldToB)
        )
    }

    private func writePairFile(_ relativePath: String, _ contents: String) throws {
        let url = workRoot
            .appendingPathComponent("project/src/main/java")
            .appendingPathComponent(relativePath)
        try Data(contents.utf8).write(to: url, options: .atomic)
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
