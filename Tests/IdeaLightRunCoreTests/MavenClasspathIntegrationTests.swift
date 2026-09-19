import XCTest
@testable import IdeaLightRunCore

/// §120.4: Maven 多模块 classpath Integration Test。
/// 真实调用 mvn compile + dependency:build-classpath，验证 reactor 依赖
/// 解析到 target/classes。本机无 mvn 时跳过。
final class MavenClasspathIntegrationTests: XCTestCase {
    var tempProject: URL!

    override func setUpWithError() throws {
        guard MavenBuildService.discoverMavenExecutable(projectRoot: FileManager.default.temporaryDirectory) != nil else {
            throw XCTSkip("系统未安装 Maven，跳过集成测试")
        }
        tempProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-it-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempProject, withIntermediateDirectories: true)
        try makeProject()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempProject)
    }

    private func makeProject() throws {
        // root
        try """
        <project xmlns="http://maven.apache.org/POM/4.0.0">
            <modelVersion>4.0.0</modelVersion>
            <groupId>com.example.it</groupId>
            <artifactId>it-root</artifactId>
            <version>1.0.0-SNAPSHOT</version>
            <packaging>pom</packaging>
            <modules>
                <module>common</module>
                <module>user-service</module>
            </modules>
        </project>
        """.write(to: tempProject.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)

        for (module, extra) in [("common", ""), ("user-service", """
        <dependencies>
            <dependency>
                <groupId>com.example.it</groupId>
                <artifactId>common</artifactId>
                <version>1.0.0-SNAPSHOT</version>
            </dependency>
        </dependencies>
        """)] {
            let dir = tempProject.appendingPathComponent(module, isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("src/main/java/com/example/it", isDirectory: true),
                withIntermediateDirectories: true
            )
            try """
            <project xmlns="http://maven.apache.org/POM/4.0.0">
                <modelVersion>4.0.0</modelVersion>
                <parent>
                    <groupId>com.example.it</groupId>
                    <artifactId>it-root</artifactId>
                    <version>1.0.0-SNAPSHOT</version>
                </parent>
                <artifactId>\(module)</artifactId>
                \(extra)
            </project>
            """.write(to: dir.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)

            let className = module == "common" ? "CommonUtil" : "UserApplication"
            try """
            package com.example.it;

            public class \(className) {
                public static void main(String[] args) {
                    System.out.println("\(className) started");
                }
            }
            """.write(
                to: dir.appendingPathComponent("src/main/java/com/example/it/\(className).java"),
                atomically: true, encoding: .utf8
            )
        }
    }

    /// 验收场景 B/C（§92/§93）的核心机制：user-service 的 classpath
    /// 应包含 common/target/classes，而不是 SNAPSHOT jar。
    func testMultiModuleClasspathResolvesToTargetClasses() throws {
        guard let maven = MavenBuildService.discoverMavenExecutable(projectRoot: tempProject) else {
            throw XCTSkip("Maven 不可用")
        }
        let reactor = MavenPomReader.collectReactor(rootPom: tempProject.appendingPathComponent("pom.xml"))
        let service = MavenBuildService(
            projectRoot: tempProject,
            mavenExecutable: maven,
            environment: MavenBuildService.buildEnvironment(javaHome: nil)
        )

        let outputFile = tempProject.appendingPathComponent("cp-out.txt")
        let entries = try service.resolveRuntimeClasspath(
            reactorModuleName: "user-service",
            hasModules: true,
            handle: nil,
            outputFile: outputFile,
            log: { _ in }
        )

        let commonClasses = tempProject
            .appendingPathComponent("common/target/classes", isDirectory: true).path
        let userClasses = tempProject
            .appendingPathComponent("user-service/target/classes", isDirectory: true).path

        XCTAssertTrue(FileManager.default.fileExists(atPath: userClasses), "user-service 应已编译")
        XCTAssertTrue(FileManager.default.fileExists(atPath: commonClasses), "common 应已编译（-am）")

        let normalized = MavenClasspathResolver.normalize(
            entries: entries,
            reactor: reactor,
            targetModuleDirectory: tempProject.appendingPathComponent("user-service", isDirectory: true)
        )
        XCTAssertTrue(normalized.contains(userClasses), "classpath 应含 user-service/target/classes")
        XCTAssertTrue(normalized.contains(commonClasses), "classpath 应含 common/target/classes（reactor 依赖）")
        XCTAssertFalse(
            normalized.contains { $0.hasSuffix("common-1.0.0-SNAPSHOT.jar") },
            "不应使用 common 的 SNAPSHOT jar（§92）"
        )
    }

    func testCompileIsIncrementalAndRepeatable() throws {
        guard let maven = MavenBuildService.discoverMavenExecutable(projectRoot: tempProject) else {
            throw XCTSkip("Maven 不可用")
        }
        let service = MavenBuildService(
            projectRoot: tempProject,
            mavenExecutable: maven,
            environment: MavenBuildService.buildEnvironment(javaHome: nil)
        )
        // 连续两次 compile：验证可重复执行（§17：不 clean，增量）
        try service.compile(reactorModuleName: nil, hasModules: false, handle: nil, log: { _ in })
        try service.compile(reactorModuleName: nil, hasModules: false, handle: nil, log: { _ in })
    }

    /// 构建期 Stop（IDEA 行为）：handle.terminate() 应终止构建进程，
    /// run 抛出 launchCancelled 而不是"构建失败"。
    func testBuildCancellationViaHandle() throws {
        let service = MavenBuildService(
            projectRoot: FileManager.default.temporaryDirectory,
            mavenExecutable: URL(fileURLWithPath: "/bin/sleep"),
            environment: ProcessInfo.processInfo.environment
        )
        let handle = ProcessHandle()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            handle.terminate()
        }
        XCTAssertThrowsError(try service.run(arguments: ["100"], handle: handle, log: { _ in })) { error in
            guard case IdeaLightRunError.launchCancelled = error else {
                return XCTFail("期望 launchCancelled，实际：\(error)")
            }
        }
        XCTAssertTrue(handle.isCancelled)
    }
}
