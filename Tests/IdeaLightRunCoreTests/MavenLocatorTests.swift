import XCTest
@testable import IdeaLightRunCore

/// §15: Maven 定位。回归——从 Dock/Finder 启动时 PATH 只有系统默认值，
/// 用户安装的 Maven 与 IDEA 自带 Maven 都必须仍然找得到。
final class MavenLocatorTests: XCTestCase {
    private var projectRoot: URL!
    private var home: URL!
    private var applications: URL!
    private let fm = FileManager.default

    /// 模拟 GUI 环境的 PATH：不含任何用户安装目录。
    let guiPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("lr-mvn-\(UUID().uuidString)", isDirectory: true)
        projectRoot = base.appendingPathComponent("project", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        applications = base.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    }

    private func locator(
        environment: [String: String]? = nil,
        knownLocations: [URL] = []
    ) -> MavenLocator {
        MavenLocator(
            projectRoot: projectRoot,
            environment: environment ?? ["PATH": guiPath],
            homeDirectory: home,
            applicationDirectories: [applications],
            knownLocations: knownLocations
        )
    }

    @discardableResult
    private func makeExecutable(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testProjectWrapperWins() throws {
        let wrapper = try makeExecutable(projectRoot.appendingPathComponent("mvnw"))
        try makeExecutable(applications.appendingPathComponent("IntelliJ IDEA.app/Contents/plugins/maven/lib/maven3/bin/mvn"))
        XCTAssertEqual(locator().firstUsable(), MavenLocator.Candidate(executable: wrapper, source: .projectWrapper))
    }

    func testNonExecutableWrapperIsSkipped() throws {
        let broken = projectRoot.appendingPathComponent("mvnw")
        try Data("#!/bin/sh\n".utf8).write(to: broken)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: broken.path)
        let mavenHome = try makeExecutable(home.appendingPathComponent("apache-maven/bin/mvn"))
        let candidate = locator(environment: ["PATH": guiPath, "MAVEN_HOME": home.appendingPathComponent("apache-maven").path]).firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, mavenHome.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .mavenHomeEnv)
    }

    /// GUI 的 PATH 里没有 mvn 时，必须回落到 IDEA 自带 Maven（这正是 IDEA 能构建的原因）。
    func testFindsIdeBundledMavenWithoutPath() throws {
        let bundled = try makeExecutable(
            applications.appendingPathComponent("IntelliJ IDEA 2025.3.app/Contents/plugins/maven/lib/maven3/bin/mvn")
        )
        let candidate = locator().firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, bundled.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .ideBundled)
    }

    /// 非 ASCII 名字与 "IntelliJ IDEA.app" 之外的前缀也要匹配（Toolbox/其他 IDE）。
    func testIdeMatchIsCaseInsensitive() throws {
        try makeExecutable(
            applications.appendingPathComponent("idea-community.app/Contents/plugins/maven/lib/maven3/bin/mvn")
        )
        XCTAssertEqual(locator().firstUsable()?.source, .ideBundled)
    }

    func testMavenHomeBeatsIdeBundled() throws {
        let mavenHomeBin = try makeExecutable(home.appendingPathComponent("maven/bin/mvn"))
        try makeExecutable(applications.appendingPathComponent("IntelliJ IDEA.app/Contents/plugins/maven/lib/maven3/bin/mvn"))
        let candidate = locator(environment: [
            "PATH": guiPath,
            "M2_HOME": home.appendingPathComponent("maven").path,
        ]).firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, mavenHomeBin.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .mavenHomeEnv)
    }

    func testWrapperDistributionUnderHome() throws {
        let dist = try makeExecutable(
            home.appendingPathComponent(".m2/wrapper/dists/apache-maven-3.9.9-bin/653a3b/apache-maven-3.9.9/bin/mvn")
        )
        let candidate = locator().firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, dist.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .wrapperDistribution)
    }

    func testNothingUsableReturnsNil() throws {
        XCTAssertNil(locator().firstUsable())
    }

    func testPathThenKnownLocation() throws {
        let fromPath = try makeExecutable(home.appendingPathComponent("bin/mvn"))
        XCTAssertEqual(
            locator(environment: ["PATH": fromPath.deletingLastPathComponent().path]).firstUsable()?.source,
            .path
        )

        let known = try makeExecutable(home.appendingPathComponent("opt/bin/mvn"))
        XCTAssertEqual(locator(knownLocations: [known]).firstUsable()?.source, .knownLocation)
    }

    /// Homebrew 装在 /opt/homebrew，从 Dock 启动时不在 PATH 里——必须靠绝对路径兜底。
    func testDefaultKnownLocationsCoverHomebrew() {
        XCTAssertTrue(
            MavenLocator.defaultKnownLocations(homeDirectory: home).contains { $0.path == "/opt/homebrew/bin/mvn" }
        )
    }

    func testDefaultApplicationDirectoriesIncludeApplications() {
        XCTAssertTrue(MavenLocator.defaultApplicationDirectories().contains { $0.path == "/Applications" })
    }

    func testFailureDetailListsSearchedLocations() throws {
        let detail = locator().failureDetail()
        XCTAssertTrue(detail.contains("项目 mvnw"), detail)
        XCTAssertTrue(detail.contains("PATH"), detail)
        XCTAssertTrue(detail.contains("/usr/bin/mvn"), "应列出 PATH 中查过的具体路径")
        XCTAssertTrue(detail.contains("mvnw"), detail)
    }
}
