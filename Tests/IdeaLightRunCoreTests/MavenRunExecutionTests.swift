import XCTest
@testable import IdeaLightRunCore

/// M5: Maven 直接运行与 JUnit（Surefire）的命令构造。
/// 这里不执行真实 Maven，只钉住参数形状、工作目录、环境与测试筛选；
/// 真实下载与编译由 `MavenClasspathIntegrationTests` 在本机覆盖。
final class MavenRunExecutionTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("lr-maven-run-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        <project>
            <modelVersion>4.0.0</modelVersion>
            <groupId>com.example</groupId>
            <artifactId>demo</artifactId>
            <version>1.0.0</version>
            <modules><module>app</module></modules>
        </project>
        """.write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        try """
        <project>
            <modelVersion>4.0.0</modelVersion>
            <parent>
                <groupId>com.example</groupId>
                <artifactId>demo</artifactId>
                <version>1.0.0</version>
            </parent>
            <artifactId>app</artifactId>
        </project>
        """.write(to: root.appendingPathComponent("app/pom.xml"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    private func service(executableName: String = "mvn") -> MavenBuildService {
        let executable = root.appendingPathComponent(executableName)
        if !fm.fileExists(atPath: executable.path) {
            try? "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return MavenBuildService(
            projectRoot: root,
            rootPomURL: root.appendingPathComponent("pom.xml"),
            mavenExecutable: executable,
            environment: ["JAVA_HOME": "/fake/jdk", "PATH": "/usr/bin:/bin"],
            jdkMajorVersion: 17
        )
    }

    private func mavenConfig(_ options: MavenRunOptions) -> RunConfiguration {
        var config = RunConfiguration(
            name: "MavenPackage",
            type: .maven,
            source: ConfigurationSource(
                kind: .dotRun,
                file: root.appendingPathComponent(".run/MavenPackage.run.xml"),
                modifiedAt: nil
            )
        )
        config.mavenOptions = options
        return config
    }

    private func context(
        workingDirectory: URL? = nil,
        environment: [String: String] = ["JAVA_HOME": "/fake/jdk", "PATH": "/usr/bin:/bin"]
    ) -> BuildInvocationContext {
        BuildInvocationContext(
            environment: environment,
            workingDirectory: workingDirectory ?? root
        )
    }

    // MARK: - Maven 直接运行

    func testDirectRunBuildsArgumentsFromSavedSettings() throws {
        let options = MavenRunOptions(
            goals: ["clean", "package"],
            commandLineOptions: "-DskipITs -Dmsg=\"hello world\"",
            profiles: ["dev"],
            properties: ["skipITs": "true"],
            vmOptions: "-Xmx256m",
            skipTests: true,
            generalArguments: ["-o"],
            selectedProjects: ["app"]
        )
        let plan = try service().mavenExecution(
            mavenConfig(options),
            module: nil,
            context: context(),
            log: { _ in }
        )

        XCTAssertEqual(plan.executable.lastPathComponent, "mvn")
        XCTAssertEqual(plan.arguments, [
            "-B", "-o",
            "-DskipITs", "-Dmsg=hello world",
            "-Pdev",
            "-DskipITs=true",
            "-pl", "app",
            "-DskipTests",
            "clean", "package",
        ])
        XCTAssertFalse(plan.arguments.contains("-nsu"), "直接运行必须保留 Maven 默认的 SNAPSHOT 更新语义")
        XCTAssertEqual(plan.environment["MAVEN_OPTS"], "-Xmx256m")
        XCTAssertEqual(plan.environment["JAVA_HOME"], "/fake/jdk", "Project JDK 必须进入 Maven 进程环境")
        XCTAssertEqual(plan.workingDirectory, root)
    }

    func testMavenWrapperDoesNotGetBatchFlag() throws {
        let plan = try service(executableName: "mvnw").mavenExecution(
            mavenConfig(MavenRunOptions(goals: ["package"])),
            module: nil,
            context: context(),
            log: { _ in }
        )
        XCTAssertEqual(plan.arguments, ["package"])
    }

    func testExplicitPomFileIsPassedWithDashF() throws {
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "<project/>".write(
            to: sub.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8
        )

        let plan = try service().mavenExecution(
            mavenConfig(MavenRunOptions(goals: ["package"], pomFileName: "sub/pom.xml")),
            module: nil,
            context: context(),
            log: { _ in }
        )
        let index = try XCTUnwrap(plan.arguments.firstIndex(of: "-f"))
        XCTAssertEqual(plan.arguments[index + 1], sub.appendingPathComponent("pom.xml").path)
    }

    func testMissingDefaultPomFailsClosed() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service().mavenExecution(
            mavenConfig(MavenRunOptions(goals: ["package"])),
            module: nil,
            context: context(workingDirectory: empty),
            log: { _ in }
        )) { error in
            guard case IdeaLightRunError.invalidConfiguration(let detail) = error else {
                return XCTFail("期望 invalidConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("pom.xml"), detail)
        }
    }

    func testUnsupportedMavenOptionFailsClosed() {
        XCTAssertThrowsError(try service().mavenExecution(
            mavenConfig(MavenRunOptions(goals: ["package"], unsupportedOptions: ["userSettingsFile"])),
            module: nil,
            context: context(),
            log: { _ in }
        )) { error in
            guard case IdeaLightRunError.unsupportedConfiguration(let detail) = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("userSettingsFile"), detail)
        }
    }

    func testUnknownJreNameFailsClosed() {
        XCTAssertThrowsError(try service().mavenExecution(
            mavenConfig(MavenRunOptions(goals: ["package"], jreName: "Corretto 17")),
            module: nil,
            context: context(),
            log: { _ in }
        )) { error in
            guard case IdeaLightRunError.unsupportedConfiguration(let detail) = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("Corretto 17"), detail)
        }
    }

    func testMacrosResolveAgainstModuleDirectory() throws {
        let moduleDirectory = root.appendingPathComponent("app", isDirectory: true)
        let module = ProjectModule(name: "app", directory: moduleDirectory, artifactId: "app")
        let plan = try service().mavenExecution(
            mavenConfig(MavenRunOptions(
                goals: ["package"],
                properties: ["built.dir": "$MODULE_DIR$/target"]
            )),
            module: module,
            context: context(),
            log: { _ in }
        )
        XCTAssertTrue(plan.arguments.contains("-Dbuilt.dir=\(moduleDirectory.path)/target"), "\(plan.arguments)")
    }

    func testIDEAContextMacroAbortsDirectRun() {
        XCTAssertThrowsError(try service().mavenExecution(
            mavenConfig(MavenRunOptions(goals: ["package"], commandLineOptions: "-Dx=$Prompt$")),
            module: nil,
            context: context(),
            log: { _ in }
        )) { error in
            guard case IdeaLightRunError.unresolvedIdeaContextMacro = error else {
                return XCTFail("期望 unresolvedIdeaContextMacro，实际 \(error)")
            }
        }
    }

    // MARK: - JUnit / Surefire

    private func writeTestSource(
        _ relativePath: String,
        className: String,
        package: String,
        method: String = "works"
    ) throws {
        let url = root.appendingPathComponent("app/src/test/java/\(relativePath)")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        package \(package);
        import org.junit.jupiter.api.Test;
        class \(className) {
            @Test
            void \(method)() {}
        }
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private func appModule() -> ProjectModule {
        ProjectModule(
            name: "app",
            directory: root.appendingPathComponent("app", isDirectory: true),
            artifactId: "app"
        )
    }

    private func junitConfig(_ target: JUnitRunOptions.Target, vmOptions: String? = nil) -> RunConfiguration {
        var config = RunConfiguration(
            name: "UnitTests",
            type: .junit,
            mainClass: "com.example.AppTest",
            moduleName: "app",
            source: ConfigurationSource(
                kind: .dotRun,
                file: root.appendingPathComponent(".run/UnitTests.run.xml"),
                modifiedAt: nil
            )
        )
        config.vmOptions = vmOptions
        config.junitOptions = JUnitRunOptions(target: target)
        return config
    }

    func testSurefireExecutionUsesModuleScopeAndExactClass() throws {
        let plan = try service().testExecution(
            junitConfig(.className("com.example.AppTest"), vmOptions: "-Xmx1g"),
            module: appModule(),
            context: context(workingDirectory: root.appendingPathComponent("app")),
            log: { _ in }
        )

        XCTAssertEqual(plan.buildSystem, .maven)
        XCTAssertEqual(plan.moduleName, "app")
        XCTAssertEqual(plan.filters, ["com.example.AppTest"])
        XCTAssertEqual(plan.process.workingDirectory, root)
        XCTAssertEqual(plan.process.arguments, [
            "-B", "-nsu",
            "-pl", "app", "-am",
            "test",
            "-Dtest=com.example.AppTest",
            "-Dsurefire.failIfNoSpecifiedTests=false",
            "-DargLine=-Xmx1g",
        ])
        XCTAssertEqual(plan.process.environment["JAVA_HOME"], "/fake/jdk")
    }

    func testSurefirePackageTargetExpandsToDiscoveredClasses() throws {
        try writeTestSource(
            "com/example/AppTest.java", className: "AppTest", package: "com.example"
        )
        try writeTestSource(
            "com/example/sub/OtherTest.java", className: "OtherTest", package: "com.example.sub"
        )

        let plan = try service().testExecution(
            junitConfig(.package("com.example")),
            module: appModule(),
            context: context(workingDirectory: root.appendingPathComponent("app")),
            log: { _ in }
        )
        XCTAssertEqual(plan.filters, ["com.example.AppTest", "com.example.sub.OtherTest"])
        XCTAssertTrue(plan.process.arguments.contains(
            "-Dtest=com.example.AppTest,com.example.sub.OtherTest"
        ))
    }

    func testSurefireRejectsCustomWorkingDirectory() {
        XCTAssertThrowsError(try service().testExecution(
            junitConfig(.className("com.example.AppTest")),
            module: appModule(),
            context: context(workingDirectory: root),
            log: { _ in }
        )) { error in
            guard case IdeaLightRunError.unsupportedConfiguration(let detail) = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("模块目录"), detail)
        }
    }

    func testSurefireRejectsProgramArguments() {
        var config = junitConfig(.className("com.example.AppTest"))
        config.junitOptions = JUnitRunOptions(
            target: .className("com.example.AppTest"),
            programArguments: "--select-class=X"
        )
        XCTAssertThrowsError(try service().testExecution(
            config,
            module: appModule(),
            context: context(workingDirectory: root.appendingPathComponent("app")),
            log: { _ in }
        )) { error in
            guard case IdeaLightRunError.unsupportedConfiguration(let detail) = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("Program Arguments"), detail)
        }
    }

    func testWholeModuleTargetWithoutTestsFailsWithNoMatchingTests() {
        XCTAssertThrowsError(try service().testExecution(
            junitConfig(.all),
            module: appModule(),
            context: context(workingDirectory: root.appendingPathComponent("app")),
            log: { _ in }
        )) { error in
            guard case IdeaLightRunError.noMatchingTests = error else {
                return XCTFail("期望 noMatchingTests，实际 \(error)")
            }
        }
    }
}
