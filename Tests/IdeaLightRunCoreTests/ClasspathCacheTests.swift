import XCTest
@testable import IdeaLightRunCore

final class ClasspathCacheTests: XCTestCase {
    var tempProject: URL!

    override func setUpWithError() throws {
        tempProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempProject, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempProject)
    }

    func testStoreAndLoadRoundtrip() throws {
        let cached = CachedClasspath(
            module: "user-service",
            entries: ["/p/user-service/target/classes", "/Users/me/.m2/repository/x.jar"],
            fingerprint: "abc123",
            resolvedAt: Date()
        )
        ClasspathCache.store(cached, projectRoot: tempProject, moduleName: "user-service")
        let loaded = ClasspathCache.load(projectRoot: tempProject, moduleName: "user-service")
        XCTAssertEqual(loaded, cached)
    }

    /// §19/§57: pom 内容变化 → fingerprint 变化
    func testFingerprintChangesWhenPomChanges() throws {
        let pom = tempProject.appendingPathComponent("pom.xml")
        try "<project/>".write(to: pom, atomically: true, encoding: .utf8)
        let before = ClasspathCache.mavenFingerprint(projectRoot: tempProject, reactorPoms: [pom], jdkMajor: 8)

        try "<project version=\"2\"/>".write(to: pom, atomically: true, encoding: .utf8)
        let after = ClasspathCache.mavenFingerprint(projectRoot: tempProject, reactorPoms: [pom], jdkMajor: 8)

        XCTAssertNotEqual(before, after)
    }

    func testFingerprintChangesWithJDK() throws {
        let pom = tempProject.appendingPathComponent("pom.xml")
        try "<project/>".write(to: pom, atomically: true, encoding: .utf8)
        let jdk8 = ClasspathCache.mavenFingerprint(projectRoot: tempProject, reactorPoms: [pom], jdkMajor: 8)
        let jdk17 = ClasspathCache.mavenFingerprint(projectRoot: tempProject, reactorPoms: [pom], jdkMajor: 17)
        XCTAssertNotEqual(jdk8, jdk17)
    }

    func testFingerprintStableForSameContent() throws {
        let pom = tempProject.appendingPathComponent("pom.xml")
        try "<project/>".write(to: pom, atomically: true, encoding: .utf8)
        let first = ClasspathCache.mavenFingerprint(projectRoot: tempProject, reactorPoms: [pom], jdkMajor: 8)
        let second = ClasspathCache.mavenFingerprint(projectRoot: tempProject, reactorPoms: [pom], jdkMajor: 8)
        XCTAssertEqual(first, second)
    }

    /// §18: reactor 内部依赖 jar → target/classes
    func testNormalizeReplacesReactorJarsWithClasses() throws {
        let root = URL(fileURLWithPath: tempProject.path, isDirectory: true)
        let commonDir = root.appendingPathComponent("common", isDirectory: true)
        let userDir = root.appendingPathComponent("user-service", isDirectory: true)
        try FileManager.default.createDirectory(at: commonDir.appendingPathComponent("target/classes", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userDir.appendingPathComponent("target/classes", isDirectory: true), withIntermediateDirectories: true)

        let reactor = [
            MavenModuleInfo(
                groupId: "com.example", artifactId: "common", version: "1.0.0-SNAPSHOT",
                packaging: "jar", directory: commonDir, pomURL: commonDir.appendingPathComponent("pom.xml")
            ),
            MavenModuleInfo(
                groupId: "com.example", artifactId: "user-service", version: "1.0.0-SNAPSHOT",
                packaging: "jar", directory: userDir, pomURL: userDir.appendingPathComponent("pom.xml")
            ),
        ]
        let entries = [
            "/Users/me/.m2/repository/org/springframework/spring-core/5.3.0/spring-core-5.3.0.jar",
            "/Users/me/.m2/repository/com/example/common/1.0.0-SNAPSHOT/common-1.0.0-SNAPSHOT.jar",
        ]

        let normalized = MavenClasspathResolver.normalize(entries: entries, reactor: reactor, targetModuleDirectory: userDir)

        XCTAssertEqual(normalized.first, userDir.appendingPathComponent("target/classes").path, "目标模块自身 classes 在最前")
        XCTAssertTrue(normalized.contains(commonDir.appendingPathComponent("target/classes").path), "common 的 SNAPSHOT jar 应替换为 target/classes")
        XCTAssertFalse(normalized.contains { $0.hasSuffix("common-1.0.0-SNAPSHOT.jar") }, "不应保留 reactor SNAPSHOT jar")
        XCTAssertTrue(normalized.contains(entries[0]), "外部依赖 jar 保留")
    }
}
