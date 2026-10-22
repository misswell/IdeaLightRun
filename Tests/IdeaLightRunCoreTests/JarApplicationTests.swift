import XCTest
@testable import IdeaLightRunCore

/// §5: JAR Application 不依赖 Main Class 与项目 classpath，
/// 启动命令必须是 `java [VM] -jar <JAR_PATH> [PROGRAM]`，参数逐项传递。
final class JarApplicationTests: XCTestCase {
    private var projectRoot: URL!
    private var jarURL: URL!
    private var fakeJavaHome: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        projectRoot = fm.temporaryDirectory
            .appendingPathComponent("lightrun-jar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: projectRoot.appendingPathComponent("lib"), withIntermediateDirectories: true)
        jarURL = projectRoot.appendingPathComponent("lib/my app.jar")
        try Data("PK".utf8).write(to: jarURL)

        fakeJavaHome = fm.temporaryDirectory
            .appendingPathComponent("lightrun-jar-jdk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fakeJavaHome.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let java = fakeJavaHome.appendingPathComponent("bin/java")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: java)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)

        addTeardownBlock { [projectRoot, fakeJavaHome] in
            try? fm.removeItem(at: projectRoot!)
            try? fm.removeItem(at: fakeJavaHome!)
        }
    }

    private func makeJDK() -> JDKInstallation {
        JDKInstallation(home: fakeJavaHome, majorVersion: 17)
    }

    private func makeConfig(
        jarPath: String? = nil,
        moduleName: String? = nil,
        vmOptions: String? = "-Xms64m -Dname=\"hello world\"",
        programArguments: String? = "--profile=\"dev test\" --port 8080",
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = ["MODE": "jar"],
        jreReference: String? = nil
    ) -> RunConfiguration {
        RunConfiguration(
            name: "StandaloneJar",
            type: .jar,
            jarPath: jarPath ?? "$PROJECT_DIR$/lib/my app.jar",
            moduleName: moduleName,
            jreReference: jreReference,
            vmOptions: vmOptions,
            programArguments: programArguments,
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables,
            source: ConfigurationSource(
                kind: .dotRun,
                file: projectRoot.appendingPathComponent(".run/StandaloneJar.run.xml"),
                modifiedAt: nil
            )
        )
    }

    private func resolve(
        _ config: RunConfiguration,
        module: ProjectModule? = nil
    ) throws -> ResolvedRunConfiguration {
        try RunConfigurationResolver().resolve(
            config: config,
            projectRoot: projectRoot,
            module: module,
            jdk: makeJDK()
        )
    }

    // MARK: - 字段解析

    func testResolverExpandsJarPathAndArguments() throws {
        let resolved = try resolve(makeConfig())

        XCTAssertEqual(resolved.jarPath, jarURL)
        XCTAssertNil(resolved.mainClass)
        XCTAssertEqual(resolved.workingDirectory, projectRoot, "JAR 默认工作目录是项目根，不是 module")
        XCTAssertEqual(resolved.vmArguments, ["-Xms64m", "-Dname=hello world"])
        XCTAssertEqual(resolved.programArguments, ["--profile=dev test", "--port", "8080"])
        XCTAssertEqual(resolved.environment["MODE"], "jar")
    }

    func testRelativeJarPathAnchorsAtProjectRoot() throws {
        let resolved = try resolve(makeConfig(jarPath: "lib/my app.jar"))
        XCTAssertEqual(resolved.jarPath, jarURL)
    }

    func testModuleMacroResolvesAgainstModuleDirectory() throws {
        let moduleDirectory = projectRoot.appendingPathComponent("service", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
        let moduleJar = moduleDirectory.appendingPathComponent("service.jar")
        try Data("PK".utf8).write(to: moduleJar)

        let config = makeConfig(jarPath: "$MODULE_DIR$/service.jar", moduleName: "service")
        let resolved = try resolve(
            config,
            module: ProjectModule(name: "service", directory: moduleDirectory)
        )

        XCTAssertEqual(resolved.jarPath, moduleJar)
        XCTAssertEqual(resolved.workingDirectory, projectRoot, "显式 Module 也不改变 JAR 的默认工作目录")
    }

    func testExplicitWorkingDirectoryIsResolved() throws {
        let work = projectRoot.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let resolved = try resolve(makeConfig(workingDirectory: "$PROJECT_DIR$/work"))
        XCTAssertEqual(resolved.workingDirectory, work)
    }

    // MARK: - 启动计划

    private func plan(workingDirectory: String? = nil, jarPath: String? = nil) throws -> ExecutableLaunchPlan {
        try JarRunPlanner.plan(
            resolved: try resolve(makeConfig(jarPath: jarPath, workingDirectory: workingDirectory)),
            jdk: makeJDK()
        )
    }

    func testPlanIsVmThenJarThenProgramArguments() throws {
        let plan = try plan()

        XCTAssertEqual(plan.executable, fakeJavaHome.appendingPathComponent("bin/java"))
        XCTAssertEqual(
            plan.arguments,
            [
                "-Xms64m", "-Dname=hello world",
                "-jar", jarURL.path,
                "--profile=dev test", "--port", "8080",
            ]
        )
        XCTAssertEqual(plan.workingDirectory, projectRoot)
    }

    /// 带空格的 JAR 路径是一个参数，展示命令只在两端加引号。
    func testJarPathWithSpacesIsOneArgument() throws {
        let plan = try plan()
        XCTAssertTrue(plan.arguments.contains(jarURL.path))
        XCTAssertTrue(plan.displayCommand.contains("\"\(jarURL.path)\""), plan.displayCommand)
    }

    func testMissingJarThrows() throws {
        let missing = projectRoot.appendingPathComponent("missing.jar")
        XCTAssertThrowsError(try plan(jarPath: missing.path)) { error in
            guard case IdeaLightRunError.jarNotFound(let path) = error else {
                return XCTFail("期望 jarNotFound，实际：\(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testUnreadableJarThrows() throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限，无法构造不可读文件")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: jarURL.path)
        XCTAssertThrowsError(try plan()) { error in
            guard case IdeaLightRunError.invalidConfiguration(let detail) = error else {
                return XCTFail("期望 invalidConfiguration，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("不可读取"), detail)
        }
    }

    // MARK: - 完整流水线

    /// 没有 pom/build.gradle 的项目也能启动 JAR：不要求构建系统。
    func testCoordinatorPreparesJarWithoutBuildSystem() async throws {
        var progressStates: [ProcessState] = []
        let execution = try await ExecutionCoordinator().prepare(
            config: makeConfig(jreReference: fakeJavaHome.path),
            projectRoot: projectRoot,
            log: { _ in },
            progress: { progressStates.append($0) }
        )
        let plan = try XCTUnwrap(execution.processPlan, "JAR 应生成单进程计划")
        XCTAssertEqual(plan.executable, fakeJavaHome.appendingPathComponent("bin/java"))
        XCTAssertEqual(plan.arguments.last, "8080")
        XCTAssertTrue(plan.arguments.contains("-jar"))
        XCTAssertEqual(progressStates, [.starting], "JAR 没有构建与 classpath 阶段")
    }

    /// Before Launch 可能生成 JAR；能力门禁只警告，真正启动前必须校验并失败。
    func testCoordinatorRejectsJarMissingAfterBeforeLaunch() async throws {
        let config = makeConfig(
            jarPath: "$PROJECT_DIR$/missing.jar",
            jreReference: fakeJavaHome.path
        )
        do {
            _ = try await ExecutionCoordinator().prepare(
                config: config,
                projectRoot: projectRoot,
                log: { _ in },
                progress: { _ in }
            )
            XCTFail("缺失的 JAR 不应生成启动计划")
        } catch let error as IdeaLightRunError {
            guard case .jarNotFound = error else {
                return XCTFail("期望 jarNotFound，实际：\(error)")
            }
        }
    }

    /// JAR 配置的 Before Launch Build 走 Maven，且作用在配置的 Module 上。
    func testCoordinatorRunsJarBeforeLaunchBuildWithMaven() async throws {
        try XCTSkipIf(TestToolchain.availableJDK() == nil, "系统没有可用 JDK，跳过启动流水线测试")
        let project = try StubMavenProject(fixture: "MavenProvidedProject")
        defer { project.delete() }
        try project.installStub(runtime: [], compile: nil)
        try project.markCompiled(["app"])

        let jar = project.root.appendingPathComponent("app/target/app.jar")
        try Data("PK".utf8).write(to: jar)
        let config = RunConfiguration(
            name: "JarWithBuild",
            type: .jar,
            jarPath: jar.path,
            moduleName: "app",
            beforeLaunchTasks: [BeforeLaunchTask(kind: .build, isEnabled: true)],
            source: ConfigurationSource(
                kind: .dotRun,
                file: project.root.appendingPathComponent(".run/JarWithBuild.run.xml"),
                modifiedAt: nil
            )
        )

        let execution = try await ExecutionCoordinator().prepare(
            config: config,
            projectRoot: project.root,
            log: { _ in },
            progress: { _ in }
        )
        let plan = try XCTUnwrap(execution.processPlan)
        // JDK 来自系统解析，JAR 参数形状不受影响。
        XCTAssertTrue(plan.arguments.contains(jar.path))
        XCTAssertEqual(project.count(containing: "compile"), 1, project.logText)
        let invocation = try XCTUnwrap(project.invocations.first)
        XCTAssertEqual(invocation.firstIndex(of: "-pl").map { invocation[$0 + 1] }, "app")
    }
}
