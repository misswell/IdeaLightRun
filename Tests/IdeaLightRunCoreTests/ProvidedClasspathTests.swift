import XCTest
@testable import IdeaLightRunCore

/// §六: IDEA 的 "Include dependencies with 'Provided' scope" 必须真的生效，
/// 并且是 classpath 的一部分（§6.1）——同一 module 的两种取值各有各的缓存，互不污染。
final class ProvidedClasspathTests: XCTestCase {
    private var project: StubMavenProject!

    private func path(_ relative: String) -> String {
        project.root.appendingPathComponent(relative).path
    }
    private var springCoreJar: String { path("m2/spring-core-5.3.2.jar") }
    private var providedLibJar: String { path("m2/provided-lib-1.0.0-SNAPSHOT.jar") }
    private var appClasses: String { path("app/target/classes") }
    private var providedLibClasses: String { path("provided-lib/target/classes") }

    override func setUpWithError() throws {
        project = try StubMavenProject(fixture: "MavenProvidedProject")
        try project.markCompiled(["app", "provided-lib"])
        // runtime = compile + runtime；compile = compile + provided + system。
        // 两段共有 spring-core，用来验证合并不是简单拼接（要按 canonical 去重）。
        try project.installStub(
            runtime: [springCoreJar],
            compile: [providedLibJar, springCoreJar]
        )
    }

    override func tearDown() {
        project.delete()
        project = nil
    }

    private func requireJDK() throws {
        try XCTSkipIf(TestToolchain.availableJDK() == nil, "系统没有可用 JDK，跳过启动流水线测试")
    }

    @discardableResult
    private func prepare(_ name: String) async throws -> JavaLaunchPlan {
        let config = try project.configuration(named: name)
        return try await JavaLauncher().prepare(
            config: config,
            projectRoot: project.root,
            log: { _ in },
            progress: { _ in }
        )
    }

    private var withoutProvidedVariant: ClasspathVariant { .maven(module: "app", includeProvided: false) }
    private var withProvidedVariant: ClasspathVariant { .maven(module: "app", includeProvided: true) }

    // MARK: - 配置读取

    /// §6.3: INCLUDE_PROVIDED_SCOPE 只有 true/false 两种写法都要能被读出来。
    func testFixtureConfigsDifferOnlyInProvidedScope() throws {
        XCTAssertFalse(try project.configuration(named: "WithoutProvided").includeProvidedDependencies)
        XCTAssertTrue(try project.configuration(named: "WithProvided").includeProvidedDependencies)
    }

    // MARK: - classpath 内容

    func testWithoutProvidedExcludesProvidedDependency() async throws {
        try requireJDK()
        let plan = try await prepare("WithoutProvided")
        XCTAssertTrue(plan.classpath.contains(appClasses), "module 自己的 target/classes 必须在：\(plan.classpath)")
        XCTAssertTrue(plan.classpath.contains(springCoreJar))
        XCTAssertFalse(
            plan.classpath.contains { $0.contains("provided-lib") },
            "未勾选 Provided 时不该出现 provided-lib：\(plan.classpath)"
        )
        XCTAssertEqual(project.count(containing: "dependency:build-classpath"), 1, "一段依赖就够")
        XCTAssertTrue(project.logText.contains("-DincludeScope=runtime"))
        XCTAssertFalse(project.logText.contains("-DincludeScope=compile"))
    }

    func testWithProvidedMergesBothScopes() async throws {
        try requireJDK()
        let plan = try await prepare("WithProvided")
        XCTAssertTrue(
            plan.classpath.contains(providedLibClasses),
            "reactor 内的 provided 依赖应映射到 target/classes（§92）：\(plan.classpath)"
        )
        XCTAssertTrue(plan.classpath.contains(springCoreJar))
        XCTAssertEqual(
            project.count(containing: "dependency:build-classpath"),
            2,
            "runtime 与 compile 各一段：\n\(project.logText)"
        )
        XCTAssertTrue(project.logText.contains("-DincludeScope=runtime"))
        XCTAssertTrue(project.logText.contains("-DincludeScope=compile"))
    }

    /// §6.2: 合并是并集，不是拼接——两段都有的依赖只出现一次。
    func testMergedClasspathDeduplicates() async throws {
        try requireJDK()
        let plan = try await prepare("WithProvided")
        XCTAssertEqual(plan.classpath.filter { $0 == springCoreJar }.count, 1, "重复：\(plan.classpath)")
        XCTAssertEqual(plan.classpath.filter { $0 == appClasses }.count, 1)
        XCTAssertEqual(plan.classpath.first, appClasses, "module 自身产物排在最前")
    }

    /// 两段解析都不许带 test scope（§6.2）。
    func testProvidedMergeNeverUsesTestScope() async throws {
        try requireJDK()
        _ = try await prepare("WithProvided")
        XCTAssertFalse(project.logText.contains("-DincludeScope=test"), project.logText)
    }

    // MARK: - 缓存隔离（§6.1）

    /// 同一 module 的两种取值共用缓存的话，第二个配置会拿到第一个的结果——
    /// 用户勾了 Provided 却少了依赖，是最难查的那类不一致。
    func testVariantsDoNotPolluteEachOther() async throws {
        try requireJDK()
        let plain = try await prepare("WithoutProvided")
        let withProvided = try await prepare("WithProvided")

        XCTAssertFalse(plain.classpath.contains { $0.contains("provided-lib") })
        XCTAssertTrue(withProvided.classpath.contains(providedLibClasses))

        // WithProvided 没有命中 WithoutProvided 的缓存：3 段解析（1 + 2）
        XCTAssertEqual(project.count(containing: "dependency:build-classpath"), 3, project.logText)

        let cachedPlain = try XCTUnwrap(ClasspathCache.load(projectRoot: project.root, variant: withoutProvidedVariant))
        let cachedProvided = try XCTUnwrap(ClasspathCache.load(projectRoot: project.root, variant: withProvidedVariant))
        XCTAssertFalse(cachedPlain.entries.contains { $0.contains("provided-lib") })
        XCTAssertTrue(cachedProvided.entries.contains(providedLibClasses))
    }

    /// 缓存命中后结果仍与冷启动一致：provided 不会被"缓存顺手丢掉"。
    func testWarmCacheKeepsProvidedVariantSeparate() async throws {
        try requireJDK()
        let cold = try await prepare("WithProvided")
        let resolvesAfterCold = project.count(containing: "dependency:build-classpath")
        let warm = try await prepare("WithProvided")

        XCTAssertEqual(project.count(containing: "dependency:build-classpath"), resolvesAfterCold, "热启动不该再解析")
        XCTAssertEqual(cold.classpath, warm.classpath)
    }

    // MARK: - 变体本身

    func testVariantIdentityCoversModuleAndProvidedFlag() {
        XCTAssertNotEqual(
            ClasspathVariant.maven(module: "app", includeProvided: false).cacheKey,
            ClasspathVariant.maven(module: "app", includeProvided: true).cacheKey
        )
        XCTAssertNotEqual(
            ClasspathVariant.maven(module: "app", includeProvided: true).cacheKey,
            ClasspathVariant.maven(module: "provided-lib", includeProvided: true).cacheKey
        )
    }
}
