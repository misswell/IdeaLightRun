import XCTest
@testable import IdeaLightRunCore

final class LaunchPlanBuilderTests: XCTestCase {
    let projectRoot = Fixtures.url("MavenMultiProject")

    /// LaunchPlanBuilder 会校验 bin/java 真实可执行，所以用临时桩而不是依赖机器的 JAVA_HOME。
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

    func testBuildPlanTokenizesAndResolves() throws {
        let plan = try LaunchPlanBuilder.build(
            config: makeConfig(),
            projectRoot: projectRoot,
            moduleDirectory: projectRoot.appendingPathComponent("gateway", isDirectory: true),
            classpath: ["/tmp/a.jar"],
            jdk: makeJDK()
        )

        // §12: VM options 分词
        XCTAssertEqual(plan.vmArguments.first, "-Xms256m")
        XCTAssertTrue(plan.vmArguments.contains("-Dname=hello world"))
        // §29: profiles 已在程序参数里显式存在时，VM 不重复注入——但这里 vm 没有该属性，因此注入
        XCTAssertTrue(plan.vmArguments.contains("-Dspring.profiles.active=dev"))

        // 程序参数分词
        XCTAssertEqual(plan.programArguments, ["--spring.profiles.active=dev", "--server.port=8081"])

        // §11: $MODULE_DIR$ 展开
        XCTAssertEqual(plan.workingDirectory.path, projectRoot.appendingPathComponent("gateway").path)

        // §28: config env 覆盖 system env
        XCTAssertEqual(plan.environment["NACOS_ADDR"], "http://localhost:8848")
        XCTAssertEqual(plan.environment["DB_PASSWORD"], "secret")
        XCTAssertNotNil(plan.environment["PATH"], "应保留系统环境")

        // §27: -cp 由 classpath 数组拼接，主类独立
        XCTAssertFalse(plan.classpath.isEmpty)
        XCTAssertTrue(plan.mainClass == "com.example.gateway.GatewayApplication")
    }

    func testProfilesNotDuplicatedWhenVMAlreadyHasIt() throws {
        var config = makeConfig()
        config.vmOptions = "-Dspring.profiles.active=test"
        config.springProfiles = ["dev"]
        let plan = try LaunchPlanBuilder.build(
            config: config,
            projectRoot: projectRoot,
            moduleDirectory: projectRoot.appendingPathComponent("gateway", isDirectory: true),
            classpath: ["/tmp/a.jar"],
            jdk: makeJDK()
        )
        // §29: 优先遵守显式配置，不重复追加
        XCTAssertEqual(plan.vmArguments.filter { $0.hasPrefix("-Dspring.profiles.active") }.count, 1)
        XCTAssertTrue(plan.vmArguments.contains("-Dspring.profiles.active=test"))
    }

    func testMissingMainClassThrows() {
        var config = makeConfig()
        config.mainClass = nil
        XCTAssertThrowsError(try LaunchPlanBuilder.build(
            config: config,
            projectRoot: projectRoot,
            moduleDirectory: projectRoot.appendingPathComponent("gateway", isDirectory: true),
            classpath: ["/tmp/a.jar"],
            jdk: makeJDK()
        )) { error in
            guard case IdeaLightRunError.mainClassNotFound = error else {
                return XCTFail("期望 mainClassNotFound，实际：\(error)")
            }
        }
    }

    func testDisplayCommandQuotesSpaces() throws {
        let plan = try LaunchPlanBuilder.build(
            config: makeConfig(),
            projectRoot: projectRoot,
            moduleDirectory: projectRoot.appendingPathComponent("gateway", isDirectory: true),
            classpath: ["/tmp/a.jar", "/tmp/b c.jar"],
            jdk: makeJDK()
        )
        // displayCommand 对整个 -cp 值加引号（它是一个参数）
        XCTAssertTrue(plan.displayCommand().contains("\"/tmp/a.jar:/tmp/b c.jar\""))
    }
}
