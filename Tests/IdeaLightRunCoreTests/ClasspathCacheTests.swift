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
        let variant = ClasspathVariant.maven(module: "user-service", includeProvided: false)
        let cached = CachedClasspath(
            module: "user-service",
            entries: ["/p/user-service/target/classes", "/Users/me/.m2/repository/x.jar"],
            fingerprint: "abc123",
            resolvedAt: Date()
        )
        ClasspathCache.store(cached, projectRoot: tempProject, variant: variant)
        let loaded = ClasspathCache.load(projectRoot: tempProject, variant: variant)
        XCTAssertEqual(loaded, cached)
    }

    /// §6.1: includeProvided 是缓存身份的一部分，两种取值不能落到同一个目录。
    func testProvidedVariantHasItsOwnCacheEntry() throws {
        let without = ClasspathVariant.maven(module: "app", includeProvided: false)
        let with = ClasspathVariant.maven(module: "app", includeProvided: true)
        XCTAssertNotEqual(ClasspathCache.cacheDirectory(projectRoot: tempProject, variant: without),
                          ClasspathCache.cacheDirectory(projectRoot: tempProject, variant: with))

        ClasspathCache.store(
            CachedClasspath(module: "app", entries: ["/only-runtime.jar"], fingerprint: "f", resolvedAt: Date()),
            projectRoot: tempProject,
            variant: without
        )
        XCTAssertNil(ClasspathCache.load(projectRoot: tempProject, variant: with), "另一变体不能被读到")

        ClasspathCache.clear(projectRoot: tempProject, moduleName: "app")
        XCTAssertNil(ClasspathCache.load(projectRoot: tempProject, variant: without))
    }

    /// §19/§57: pom 内容变化 → fingerprint 变化
    func testFingerprintChangesWhenPomChanges() throws {        let pom = tempProject.appendingPathComponent("pom.xml")
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

        XCTAssertEqual(normalized.first, MavenClasspathResolver.canonicalPath(userDir.appendingPathComponent("target/classes").path), "目标模块自身 classes 在最前")
        XCTAssertTrue(normalized.contains(MavenClasspathResolver.canonicalPath(commonDir.appendingPathComponent("target/classes").path)), "common 的 SNAPSHOT jar 应替换为 target/classes")
        XCTAssertFalse(normalized.contains { $0.hasSuffix("common-1.0.0-SNAPSHOT.jar") }, "不应保留 reactor SNAPSHOT jar")
        XCTAssertTrue(normalized.contains(MavenClasspathResolver.canonicalPath(entries[0])), "外部依赖 jar 保留")
    }

    /// 父模块名是长名兄弟的前缀（tg-tenant / tg-tenant-server）：版本已知的
    /// 精确匹配必须赢，长名兄弟的 jar 不能被父名前缀抢走换成父模块的 classes。
    func testNormalizePrefersExactVersionOverShorterPrefix() throws {
        let root = URL(fileURLWithPath: tempProject.path, isDirectory: true)
        let parentDir = root.appendingPathComponent("tg-tenant", isDirectory: true)
        let serverDir = root.appendingPathComponent("tg-tenant-server", isDirectory: true)
        // 父模块也带 target/classes（packaging 不是 pom 的极端情况），误匹配才会真正改写
        try FileManager.default.createDirectory(at: parentDir.appendingPathComponent("target/classes", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("target/classes", isDirectory: true), withIntermediateDirectories: true)

        let reactor = [
            MavenModuleInfo(
                groupId: "com.example", artifactId: "tg-tenant", version: "3.0.7-SNAPSHOT",
                packaging: "pom", directory: parentDir, pomURL: parentDir.appendingPathComponent("pom.xml")
            ),
            MavenModuleInfo(
                groupId: "com.example", artifactId: "tg-tenant-server", version: "3.0.7-SNAPSHOT",
                packaging: "jar", directory: serverDir, pomURL: serverDir.appendingPathComponent("pom.xml")
            ),
        ]
        let entries = [
            "/Users/me/.m2/repository/com/example/tg-tenant-server/3.0.7-SNAPSHOT/tg-tenant-server-3.0.7-SNAPSHOT.jar",
        ]

        let normalized = MavenClasspathResolver.normalize(entries: entries, reactor: reactor, targetModuleDirectory: serverDir)

        XCTAssertTrue(
            normalized.contains(MavenClasspathResolver.canonicalPath(serverDir.appendingPathComponent("target/classes").path)),
            "server 的 jar 应替换为 server 自己的 target/classes"
        )
        XCTAssertFalse(
            normalized.contains(MavenClasspathResolver.canonicalPath(parentDir.appendingPathComponent("target/classes").path)),
            "父模块的 classes 不应混进来"
        )
    }

    /// 版本都未知时的前缀匹配取最长 artifactId：app-api 的 jar 配给 app-api，不配给 app。
    /// 目标模块用第三个 server（否则 app 作为目标模块自身必然进 classpath，无法区分）。
    func testNormalizePrefixMatchPicksLongestArtifactId() throws {
        let root = URL(fileURLWithPath: tempProject.path, isDirectory: true)
        let appDir = root.appendingPathComponent("app", isDirectory: true)
        let apiDir = root.appendingPathComponent("app-api", isDirectory: true)
        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir.appendingPathComponent("target/classes", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apiDir.appendingPathComponent("target/classes", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("target/classes", isDirectory: true), withIntermediateDirectories: true)

        let reactor = [
            MavenModuleInfo(groupId: "com.example", artifactId: "app", version: nil, packaging: "jar", directory: appDir, pomURL: appDir.appendingPathComponent("pom.xml")),
            MavenModuleInfo(groupId: "com.example", artifactId: "app-api", version: nil, packaging: "jar", directory: apiDir, pomURL: apiDir.appendingPathComponent("pom.xml")),
            MavenModuleInfo(groupId: "com.example", artifactId: "server", version: nil, packaging: "jar", directory: serverDir, pomURL: serverDir.appendingPathComponent("pom.xml")),
        ]
        let entries = [
            "/Users/me/.m2/repository/com/example/app-api/1.0-SNAPSHOT/app-api-1.0-SNAPSHOT.jar",
        ]

        let normalized = MavenClasspathResolver.normalize(entries: entries, reactor: reactor, targetModuleDirectory: serverDir)

        XCTAssertTrue(normalized.contains(MavenClasspathResolver.canonicalPath(apiDir.appendingPathComponent("target/classes").path)), "应替换为 app-api 的 classes")
        XCTAssertFalse(normalized.contains(MavenClasspathResolver.canonicalPath(appDir.appendingPathComponent("target/classes").path)), "不能误配给 app 模块")
        XCTAssertFalse(normalized.contains { $0.hasSuffix("app-api-1.0-SNAPSHOT.jar") }, "不应保留 reactor SNAPSHOT jar")
    }

    // MARK: - §P0-7 缓存可用性（条目存在性）

    private func makeClassesDir() throws -> URL {
        let dir = tempProject.appendingPathComponent("target/classes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 条目全部存在 + fingerprint 匹配 → 可用
    func testValidateAcceptsCacheWithExistingEntries() throws {
        let classes = try makeClassesDir()
        let validity = ClasspathCache.validate(
            CachedClasspath(module: "app", entries: [classes.path], fingerprint: "f", resolvedAt: Date()),
            fingerprint: "f"
        )
        XCTAssertEqual(validity, .usable)
    }

    /// clean 只删 target/、pom 未变（fingerprint 不变）：缓存必须判为条目缺失，
    /// 而不是命中指向已删产物的死路径。
    func testValidateRejectsCacheAfterCleanRemovedEntries() throws {
        let classes = try makeClassesDir()
        let cached = CachedClasspath(module: "app", entries: [classes.path], fingerprint: "f", resolvedAt: Date())
        XCTAssertEqual(ClasspathCache.validate(cached, fingerprint: "f"), .usable)

        try FileManager.default.removeItem(at: classes) // 模拟 clean
        guard case .entriesMissing(let missing) = ClasspathCache.validate(cached, fingerprint: "f") else {
            return XCTFail("clean 后必须报条目缺失，实际：\(ClasspathCache.validate(cached, fingerprint: "f"))")
        }
        XCTAssertEqual(missing, [classes.path])
    }

    /// fingerprint 不匹配仍报 stale（P0-7 只加强条目校验，不改 fingerprint 语义）
    func testValidateRejectsStaleFingerprint() throws {
        let classes = try makeClassesDir()
        let validity = ClasspathCache.validate(
            CachedClasspath(module: "app", entries: [classes.path], fingerprint: "old", resolvedAt: Date()),
            fingerprint: "new"
        )
        XCTAssertEqual(validity, .stale)
    }

    /// 空缓存不可用
    func testValidateRejectsEmptyEntries() {
        XCTAssertEqual(
            ClasspathCache.validate(
                CachedClasspath(module: "app", entries: [], fingerprint: "f", resolvedAt: Date()),
                fingerprint: "f"
            ),
            .empty
        )
    }

    // MARK: - Gradle 变体与指纹（M4）

    /// Gradle 的缓存身份是 project path，不是显示名；构建系统与 provided 也必须分开。
    func testGradleVariantIdentityIsSeparate() {
        let app = ClasspathVariant.gradle(module: ":app", includeProvided: false)
        XCTAssertNotEqual(app, .gradle(module: ":app", includeProvided: true))
        XCTAssertNotEqual(app, .gradle(module: ":library:app", includeProvided: false))
        XCTAssertNotEqual(app, .maven(module: ":app", includeProvided: false))
        XCTAssertNotEqual(
            ClasspathCache.cacheDirectory(projectRoot: tempProject, variant: app),
            ClasspathCache.cacheDirectory(
                projectRoot: tempProject,
                variant: .maven(module: ":app", includeProvided: false)
            )
        )
    }

    func testGradleOutputAndInitScriptLiveInVariantDirectory() {
        let variant = ClasspathVariant.gradle(module: ":app", includeProvided: false)
        let directory = ClasspathCache.cacheDirectory(projectRoot: tempProject, variant: variant)
        let output = ClasspathCache.gradleOutputFileURL(projectRoot: tempProject, variant: variant)
        let initScript = ClasspathCache.gradleInitScriptURL(projectRoot: tempProject, variant: variant)
        XCTAssertEqual(output.deletingLastPathComponent(), directory)
        XCTAssertEqual(initScript.deletingLastPathComponent(), directory)
        XCTAssertNotEqual(output, initScript)
    }

    /// §57: Gradle 指纹覆盖构建脚本、JDK、wrapper 与 GRADLE_USER_HOME 全局配置。
    func testGradleFingerprintTracksAllClasspathInputs() throws {
        let root = URL(fileURLWithPath: tempProject.path, isDirectory: true)
        let settings = root.appendingPathComponent("settings.gradle")
        let appBuild = root.appendingPathComponent("app/build.gradle")
        try FileManager.default.createDirectory(
            at: appBuild.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "rootProject.name = 'demo'\n".write(to: settings, atomically: true, encoding: .utf8)
        try "".write(to: appBuild, atomically: true, encoding: .utf8)

        let userHome = root.appendingPathComponent("gradle-home", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let globalProperties = userHome.appendingPathComponent("gradle.properties")
        try "org.gradle.jvmargs=-Xmx1g\n".write(to: globalProperties, atomically: true, encoding: .utf8)

        let wrapperDirectory = root.appendingPathComponent("gradle/wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        let wrapperProperties = wrapperDirectory.appendingPathComponent("gradle-wrapper.properties")
        try "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.7-bin.zip\n".write(
            to: wrapperProperties, atomically: true, encoding: .utf8
        )

        func fingerprint(jdk: Int? = 17) -> String {
            ClasspathCache.gradleFingerprint(
                projectRoot: root,
                buildFiles: [settings, appBuild],
                jdkMajor: jdk,
                gradleUserHome: userHome
            )
        }

        let baseline = fingerprint()
        XCTAssertEqual(baseline, fingerprint(), "内容不变时指纹必须稳定")

        try "dependencies { implementation 'x:y:1.0' }\n".write(
            to: appBuild, atomically: true, encoding: .utf8
        )
        let afterBuildFile = fingerprint()
        XCTAssertNotEqual(afterBuildFile, baseline, "构建脚本变化必须失效")

        let afterJDK = fingerprint(jdk: 21)
        XCTAssertNotEqual(afterJDK, afterBuildFile, "JDK major 变化必须失效")

        try "org.gradle.jvmargs=-Xmx2g\n".write(
            to: globalProperties, atomically: true, encoding: .utf8
        )
        let afterGlobal = fingerprint(jdk: 21)
        XCTAssertNotEqual(afterGlobal, afterJDK, "GRADLE_USER_HOME 全局配置变化必须失效")

        try "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.9-bin.zip\n".write(
            to: wrapperProperties, atomically: true, encoding: .utf8
        )
        let afterWrapper = fingerprint(jdk: 21)
        XCTAssertNotEqual(afterWrapper, afterGlobal, "wrapper 版本变化必须失效")

        let initDirectory = userHome.appendingPathComponent("init.d", isDirectory: true)
        try FileManager.default.createDirectory(at: initDirectory, withIntermediateDirectories: true)
        try "allprojects { repositories { mavenLocal() } }\n".write(
            to: initDirectory.appendingPathComponent("repos.gradle"), atomically: true, encoding: .utf8
        )
        XCTAssertNotEqual(fingerprint(jdk: 21), afterWrapper, "GRADLE_USER_HOME/init.d 变化必须失效")
    }
}
