import XCTest
@testable import IdeaLightRunCore

final class JavaRunPlannerTests: XCTestCase {
    let projectRoot = Fixtures.url("MavenMultiProject")

    /// JavaRunPlanner 会校验 bin/java 真实可执行，所以用临时桩而不是依赖机器的 JAVA_HOME。
    private var fakeJavaHome: URL!

    override func setUpWithError() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightrun-fake-jdk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let java = home.appendingPathComponent("bin/java")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: java)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        fakeJavaHome = home
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    }

    private func makeConfig() -> RunConfiguration {
        RunConfiguration(
            name: "GatewayApplication",
            type: .springBoot,
            mainClass: "com.example.gateway.GatewayApplication",
            moduleName: "gateway",
            vmOptions: "-Xms256m -Dname=\"hello world\"",
            programArguments: "--spring.profiles.active=dev --server.port=\"8080 8081\"".replacingOccurrences(of: "8080 8081", with: "8081"),
            workingDirectory: "$MODULE_DIR$",
            environmentVariables: ["NACOS_ADDR": "http://localhost:8848", "DB_PASSWORD": "secret"],
            springProfiles: ["dev"],
            source: ConfigurationSource(kind: .dotRun, file: projectRoot, modifiedAt: nil)
        )
    }

    private func makeJDK() -> JDKInstallation {
        JDKInstallation(home: fakeJavaHome, majorVersion: 8)
    }

    /// 与 `ExecutionCoordinator` 同一条链：先解析配置，再交给 planner。
    private func plan(classpath: [String] = ["/tmp/a.jar"], config: RunConfiguration? = nil) throws -> ExecutableLaunchPlan {
        let resolved = try RunConfigurationResolver().resolve(
            config: config ?? makeConfig(),
            projectRoot: projectRoot,
            module: ProjectModule(
                name: "gateway",
                directory: projectRoot.appendingPathComponent("gateway", isDirectory: true)
            ),
            jdk: makeJDK()
        )
        return try JavaRunPlanner.plan(resolved: resolved, classpath: classpath, jdk: makeJDK())
    }

    /// §7: 计划只剩 argv，因此按 `-cp` 这条分界线读回 VM / 程序参数。
    private func segments(_ plan: ExecutableLaunchPlan) -> (vm: [String], classpathValue: String, mainClass: String, program: [String]) {
        guard let dash = plan.arguments.firstIndex(of: "-cp"), dash + 2 < plan.arguments.count else {
            return (Array(plan.arguments.dropLast(0)), "", "", [])
        }
        return (
            Array(plan.arguments[..<dash]),
            plan.arguments[dash + 1],
            plan.arguments[dash + 2],
            Array(plan.arguments[(dash + 3)...])
        )
    }

    func testPlanTokenizesAndResolves() throws {
        let plan = try plan()
        let segments = segments(plan)

        XCTAssertEqual(plan.executable.path, fakeJavaHome.appendingPathComponent("bin/java").path)

        // §12: VM options 分词
        XCTAssertEqual(segments.vm.first, "-Xms256m")
        XCTAssertTrue(segments.vm.contains("-Dname=hello world"))
        // §29: profiles 已在程序参数里显式存在时，VM 不重复注入——但这里 vm 没有该属性，因此注入
        XCTAssertTrue(segments.vm.contains("-Dspring.profiles.active=dev"))

        // 程序参数分词
        XCTAssertEqual(segments.program, ["--spring.profiles.active=dev", "--server.port=8081"])

        // §11: $MODULE_DIR$ 展开
        XCTAssertEqual(plan.workingDirectory.path, projectRoot.appendingPathComponent("gateway").path)

        // §28: config env 覆盖 system env
        XCTAssertEqual(plan.environment["NACOS_ADDR"], "http://localhost:8848")
        XCTAssertEqual(plan.environment["DB_PASSWORD"], "secret")
        XCTAssertNotNil(plan.environment["PATH"], "应保留系统环境")

        // §27: -cp 由 classpath 数组以 ":" 连接，主类紧跟其后
        XCTAssertEqual(segments.classpathValue, "/tmp/a.jar")
        XCTAssertEqual(segments.mainClass, "com.example.gateway.GatewayApplication")
    }

    /// §7: 参数的相对顺序就是 java 命令的形状，会话拿到的是同一份 argv。
    func testArgumentOrderMatchesJavaInvocation() throws {
        let plan = try plan(classpath: ["/tmp/a.jar", "/tmp/b.jar"])
        XCTAssertEqual(
            plan.arguments,
            ["-Xms256m", "-Dname=hello world", "-Dspring.profiles.active=dev",
             "-cp", "/tmp/a.jar:/tmp/b.jar", "com.example.gateway.GatewayApplication",
             "--spring.profiles.active=dev", "--server.port=8081"]
        )
    }

    func testProfilesNotDuplicatedWhenVMAlreadyHasIt() throws {
        var config = makeConfig()
        config.vmOptions = "-Dspring.profiles.active=test"
        config.springProfiles = ["dev"]
        let vm = segments(try plan(config: config)).vm
        // §29: 优先遵守显式配置，不重复追加
        XCTAssertEqual(vm.filter { $0.hasPrefix("-Dspring.profiles.active") }.count, 1)
        XCTAssertTrue(vm.contains("-Dspring.profiles.active=test"))
    }

    func testMissingMainClassThrows() {
        var config = makeConfig()
        config.mainClass = nil
        XCTAssertThrowsError(try plan(config: config)) { error in
            guard case IdeaLightRunError.mainClassNotFound = error else {
                return XCTFail("期望 mainClassNotFound，实际：\(error)")
            }
        }
    }

    func testEmptyClasspathThrows() {
        XCTAssertThrowsError(try plan(classpath: [])) { error in
            guard case IdeaLightRunError.classpathResolveFailed = error else {
                return XCTFail("期望 classpathResolveFailed，实际：\(error)")
            }
        }
    }

    func testDisplayCommandQuotesSpaces() throws {
        let plan = try plan(classpath: ["/tmp/a.jar", "/tmp/b c.jar"])
        // displayCommand 对整个 -cp 值加引号（它是一个参数）
        XCTAssertTrue(plan.displayCommand.contains("\"/tmp/a.jar:/tmp/b c.jar\""))
    }
}
