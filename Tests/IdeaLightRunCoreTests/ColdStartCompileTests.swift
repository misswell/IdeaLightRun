import XCTest
@testable import IdeaLightRunCore

/// §3.1/§3.3/§12: Cold Start 只 compile 一次、只解析一次；
/// Warm Start 命中缓存时不再解析依赖；"Do not build" 一次都不 compile。
///
/// Maven 由 `StubMavenProject` 生成的假 mvnw 顶替：真实依赖解析既慢又需要网络，
/// 而这里要断言的是"调用次数与每次调用的参数"。真实 Maven 的语义由
/// `MavenClasspathIntegrationTests` 覆盖。
final class ColdStartCompileTests: XCTestCase {
    private var project: StubMavenProject!

    override func setUpWithError() throws {
        project = try StubMavenProject(fixture: "MavenProvidedProject")
        try project.markCompiled(["app", "provided-lib"])
        try project.installStub(
            runtime: [
                project.root.appendingPathComponent("m2/spring-core-5.3.2.jar").path,
                project.root.appendingPathComponent("app/target/classes").path,
            ],
            compile: nil
        )
    }

    override func tearDown() {
        project.delete()
        project = nil
    }

    /// 走完整启动流水线需要真实 JDK（LaunchPlan 要指向 <jdk>/bin/java）。
    private func requireJDK() throws {
        try XCTSkipIf(
            TestToolchain.availableJDK() == nil,
            "系统没有可用 JDK，跳过启动流水线测试"
        )
    }

    @discardableResult
    private func prepare(_ name: String) async throws -> [ProcessState] {
        let config = try project.configuration(named: name)
        var states: [ProcessState] = []
        let plan = try await JavaLauncher().prepare(
            config: config,
            projectRoot: project.root,
            log: { _ in },
            progress: { states.append($0) }
        )
        XCTAssertFalse(plan.classpath.isEmpty, "classpath 为空说明解析没落地")
        return states
    }

    // MARK: - 冷启动

    /// 配置里有 Make：compile 恰好 1 次，dependency:build-classpath 恰好 1 次，
    /// 而且两者在同一次 Maven 调用里（兄弟模块的 SNAPSHOT 只有同会话编译过才解析得到）。
    func testColdStartCompilesAndResolvesExactlyOnce() async throws {
        try requireJDK()
        let states = try await prepare("WithoutProvided")

        XCTAssertEqual(project.count(containing: "compile"), 1, "compile 次数：\n\(project.logText)")
        XCTAssertEqual(project.count(containing: "dependency:build-classpath"), 1)
        XCTAssertEqual(
            project.count(containingAll: ["compile", "dependency:build-classpath"]),
            1,
            "Build 与依赖解析必须合并成一次调用，否则 compile 会跑两遍"
        )
        XCTAssertEqual(states, [.building, .resolvingClasspath, .starting])
    }

    /// Make 走多模块的参数形状：`-pl <module> -am -DskipTests`，不带 clean。
    func testColdStartUsesModuleScopedIncrementalBuild() async throws {
        try requireJDK()
        _ = try await prepare("WithoutProvided")
        let invocation = try XCTUnwrap(project.invocations.first)
        XCTAssertEqual(invocation.first, "-nsu", "mvnw 不加 -B，但要 -nsu")
        XCTAssertEqual(invocation.firstIndex(of: "-pl").map { invocation[$0 + 1] }, "app")
        XCTAssertTrue(invocation.contains("-am"))
        XCTAssertTrue(invocation.contains("-DskipTests"))
        XCTAssertFalse(invocation.contains("clean"), "增量编译，不做 clean")
    }

    // MARK: - 热启动

    /// §3.1 Warm Start：缓存命中时不再执行 dependency:build-classpath。
    func testWarmStartDoesNotResolveClasspathAgain() async throws {
        try requireJDK()
        _ = try await prepare("WithoutProvided")
        let afterCold = project.count(containing: "dependency:build-classpath")

        _ = try await prepare("WithoutProvided")
        XCTAssertEqual(afterCold, 1)
        XCTAssertEqual(
            project.count(containing: "dependency:build-classpath"),
            1,
            "命中缓存后不该再解析依赖：\n\(project.logText)"
        )
    }

    /// 缓存命中时 Build 仍要执行——只是单独跑，不再搭依赖解析的车。
    func testWarmStartStillBuildsButAlone() async throws {
        try requireJDK()
        _ = try await prepare("WithoutProvided")
        _ = try await prepare("WithoutProvided")

        let merged = project.count(containingAll: ["compile", "dependency:build-classpath"])
        let standalone = project.count(containing: "compile") - merged
        XCTAssertEqual(merged, 1, "只有冷启动那次合并调用")
        XCTAssertEqual(standalone, 1, "热启动那次 Build 是独立的 compile")
    }

    // MARK: - Do not build

    /// §3.3/§11: "Do not build before run" 必须真的不 Build。
    func testDoNotBuildNeverCompiles() async throws {
        try requireJDK()
        _ = try await prepare("NoBuild")

        XCTAssertEqual(project.count(containing: "compile"), 0, "一次都不该编译：\n\(project.logText)")
        XCTAssertEqual(project.count(containing: "dependency:build-classpath"), 1, "依赖解析仍需要")
        let resolve = try XCTUnwrap(project.invocations.first { $0.contains("dependency:build-classpath") })
        XCTAssertFalse(resolve.contains("compile"))
    }

    /// §3.3/§11: 两次都不 Build 时也不该被缓存"顺手"触发编译。
    func testDoNotBuildStaysQuietWhenWarm() async throws {
        try requireJDK()
        _ = try await prepare("NoBuild")
        _ = try await prepare("NoBuild")
        XCTAssertEqual(project.count(containing: "compile"), 0)
        XCTAssertEqual(project.count(containing: "dependency:build-classpath"), 1)
    }

    // MARK: - 参数形状（不依赖 JDK，CI 上必跑）

    func testCompileArgumentShape() {
        let mvnw = URL(fileURLWithPath: "/tmp/proj/mvnw")
        XCTAssertEqual(
            MavenBuildService.compileArguments(
                mavenExecutable: mvnw, noSnapshotUpdates: true, reactorModuleName: "app", hasModules: true
            ),
            ["-nsu", "-DskipTests", "-pl", "app", "-am", "compile"]
        )
        XCTAssertEqual(
            MavenBuildService.compileArguments(
                mavenExecutable: mvnw, noSnapshotUpdates: false, reactorModuleName: nil, hasModules: false
            ),
            ["-DskipTests", "compile"]
        )
        // 根模块不需要 -pl；单模块项目也一样
        XCTAssertEqual(
            MavenBuildService.compileArguments(
                mavenExecutable: mvnw, noSnapshotUpdates: false, reactorModuleName: "app", hasModules: false
            ),
            ["-DskipTests", "compile"]
        )
    }

    func testClasspathArgumentsCarryCompileOnlyWhenRequested() {
        let mvnw = URL(fileURLWithPath: "/tmp/proj/mvnw")
        let out = URL(fileURLWithPath: "/tmp/cp.txt")
        XCTAssertEqual(
            MavenBuildService.classpathArguments(
                mavenExecutable: mvnw, noSnapshotUpdates: false, scope: .runtime,
                lifecyclePhase: nil, reactorModuleName: "app", hasModules: true, outputFile: out
            ),
            [
                "-DskipTests", "-pl", "app", "-am",
                "dependency:build-classpath", "-DincludeScope=runtime", "-Dmdep.outputFile=/tmp/cp.txt",
            ]
        )
        let merged = MavenBuildService.classpathArguments(
            mavenExecutable: mvnw, noSnapshotUpdates: false, scope: .compile,
            lifecyclePhase: "compile", reactorModuleName: nil, hasModules: false, outputFile: out
        )
        XCTAssertEqual(merged.firstIndex(of: "compile").map { merged[($0 + 1)] }, "dependency:build-classpath")
        XCTAssertTrue(merged.contains("-DincludeScope=compile"))
    }

    /// 系统 mvn 走 -B 降噪，mvnw 自带输出不加。
    func testSystemMavenGetsBatchFlag() {
        let arguments = MavenBuildService.classpathArguments(
            mavenExecutable: URL(fileURLWithPath: "/usr/local/bin/mvn"),
            noSnapshotUpdates: true, scope: .runtime, lifecyclePhase: nil,
            reactorModuleName: nil, hasModules: false,
            outputFile: URL(fileURLWithPath: "/tmp/cp.txt")
        )
        XCTAssertEqual(arguments.prefix(2), ["-B", "-nsu"])
    }

    /// §6.2: 两段解析都用 includeScope，绝不出现 test scope。
    func testClasspathNeverUsesTestScope() throws {
        let mvnw = URL(fileURLWithPath: "/tmp/proj/mvnw")
        for scope in MavenClasspathScope.allCases {
            let arguments = MavenBuildService.classpathArguments(
                mavenExecutable: mvnw, noSnapshotUpdates: false, scope: scope, lifecyclePhase: nil,
                reactorModuleName: nil, hasModules: false, outputFile: URL(fileURLWithPath: "/tmp/cp.txt")
            )
            XCTAssertTrue(arguments.contains("-DincludeScope=\(scope.rawValue)"))
            XCTAssertFalse(arguments.contains { $0.contains("test") }, "\(scope)：\(arguments)")
        }
    }
}
