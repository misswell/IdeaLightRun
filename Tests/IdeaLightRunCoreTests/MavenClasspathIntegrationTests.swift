import XCTest
@testable import IdeaLightRunCore

/// §120.4 + §9: Maven 多模块 classpath Integration Test。
/// 真实调用 mvn compile + dependency:build-classpath，验证 `BuildSystemAdapter`
/// 交出的 classpath 把 reactor 依赖解析到 target/classes——`-pl` 范围、归一化、
/// 缓存全在适配器内部，测试只按接口问它要东西。本机无 mvn 时跳过。
final class MavenClasspathIntegrationTests: XCTestCase {
    var tempProject: URL!
    private let fm = FileManager.default

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
        // 适配器会把真实 classpath 写进 ~/Library/Caches，按临时目录清掉，
        // 否则每次跑集成测试都在攒垃圾。
        for module in ["it-root", "common", "user-service"] {
            ClasspathCache.clear(projectRoot: tempProject, moduleName: module)
        }
        try? fm.removeItem(at: tempProject)
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

    /// 项目级 Maven 适配器：启动流水线拿到的同一类型，走同一组接口。
    private func makeService() throws -> MavenBuildService {
        let maven = try XCTUnwrap(
            MavenBuildService.discoverMavenExecutable(projectRoot: tempProject),
            "Maven 不可用"
        )
        return MavenBuildService(
            projectRoot: tempProject,
            rootPomURL: tempProject.appendingPathComponent("pom.xml"),
            mavenExecutable: maven,
            environment: MavenBuildService.buildEnvironment(javaHome: nil)
        )
    }

    /// §9: 调用方只给模块与缓存身份，不再传 reactorModuleName / hasModules。
    private func buildTarget(_ module: String, includeProvided: Bool = false) -> BuildTarget {
        BuildTarget(
            module: ProjectModule(
                name: module,
                directory: tempProject.appendingPathComponent(module, isDirectory: true)
            ),
            variant: .maven(module: module, includeProvided: includeProvided)
        )
    }

    /// 验收场景 B/C（§92/§93）的核心机制：user-service 的 classpath
    /// 应包含 common/target/classes，而不是 SNAPSHOT jar。
    func testMultiModuleClasspathResolvesToTargetClasses() throws {
        let service = try makeService()
        let target = buildTarget("user-service")
        let commonClasses = tempProject
            .appendingPathComponent("common/target/classes", isDirectory: true).path
        let userClasses = tempProject
            .appendingPathComponent("user-service/target/classes", isDirectory: true).path

        // §3.1/§3.3: withBuild 为真时 compile 与 dependency:build-classpath 合并为一次调用
        // ——兄弟模块的 SNAPSHOT 只有在同一次会话里编译过才解析得到。
        let entries = try service.runtimeClasspath(target, withBuild: true, handle: nil, log: { _ in })

        XCTAssertTrue(fm.fileExists(atPath: userClasses), "user-service 应已编译")
        XCTAssertTrue(fm.fileExists(atPath: commonClasses), "common 应已编译（-am）")

        XCTAssertTrue(entries.contains(userClasses), "classpath 应含 user-service/target/classes")
        XCTAssertTrue(entries.contains(commonClasses), "classpath 应含 common/target/classes（reactor 依赖）")
        XCTAssertFalse(
            entries.contains { $0.hasSuffix("common-1.0.0-SNAPSHOT.jar") },
            "不应使用 common 的 SNAPSHOT jar（§92）"
        )

        // 解析过一次即已缓存；下一次不再起 dependency:build-classpath。
        XCTAssertTrue(service.hasFreshClasspathCache(for: target))
        XCTAssertEqual(
            try service.runtimeClasspath(target, withBuild: false, handle: nil, log: { _ in }),
            entries
        )
    }

    func testCompileIsIncrementalAndRepeatable() throws {
        let service = try makeService()
        // 连续两次 compile：验证可重复执行（§17：不 clean，增量）
        try service.buildModule(buildTarget("user-service"), handle: nil, log: { _ in })
        try service.buildModule(buildTarget("user-service"), handle: nil, log: { _ in })
    }

    /// 构建期 Stop（IDEA 行为）：handle.terminate() 应终止构建进程，
    /// run 抛出 launchCancelled 而不是"构建失败"。
    func testBuildCancellationViaHandle() throws {
        let service = MavenBuildService(
            projectRoot: fm.temporaryDirectory,
            rootPomURL: fm.temporaryDirectory.appendingPathComponent("pom.xml"),
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
