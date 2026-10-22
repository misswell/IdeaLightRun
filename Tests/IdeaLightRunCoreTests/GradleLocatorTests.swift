import XCTest
@testable import IdeaLightRunCore

/// §15: 从 Dock 启动的 GUI 看不到 Homebrew / SDKMAN 的 PATH，
/// Gradle 定位必须按绝对路径兜底，并且项目自带 gradlew 永远优先。
final class GradleLocatorTests: XCTestCase {
    private var base: URL!
    private var projectRoot: URL!
    private var home: URL!
    private let fm = FileManager.default
    private let guiPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("lr-gradle-locator-\(UUID().uuidString)", isDirectory: true)
        projectRoot = base.appendingPathComponent("project", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.base) }
    }

    private func locator(
        environment: [String: String]? = nil,
        knownLocations: [URL] = []
    ) -> GradleLocator {
        GradleLocator(
            projectRoot: projectRoot,
            environment: environment ?? ["PATH": guiPath],
            homeDirectory: home,
            knownLocations: knownLocations
        )
    }

    @discardableResult
    private func makeExecutable(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testProjectWrapperWinsOverEverythingElse() throws {
        let wrapper = try makeExecutable(projectRoot.appendingPathComponent("gradlew"))
        let pathGradle = try makeExecutable(home.appendingPathComponent("bin/gradle"))
        let candidate = locator(environment: ["PATH": pathGradle.deletingLastPathComponent().path]).firstUsable()
        XCTAssertEqual(candidate, GradleLocator.Candidate(executable: wrapper, source: .projectWrapper))
    }

    func testNonExecutableWrapperIsSkipped() throws {
        let broken = projectRoot.appendingPathComponent("gradlew")
        try Data("#!/bin/sh\n".utf8).write(to: broken)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: broken.path)
        let gradleHome = try makeExecutable(home.appendingPathComponent("gradle/bin/gradle"))
        let candidate = locator(environment: [
            "PATH": guiPath,
            "GRADLE_HOME": gradleHome.deletingLastPathComponent().deletingLastPathComponent().path,
        ]).firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, gradleHome.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .gradleHomeEnv)
    }

    func testPathThenKnownLocation() throws {
        let fromPath = try makeExecutable(home.appendingPathComponent("bin/gradle"))
        XCTAssertEqual(
            locator(environment: ["PATH": fromPath.deletingLastPathComponent().path]).firstUsable()?.source,
            .path
        )

        let known = try makeExecutable(home.appendingPathComponent("opt/bin/gradle"))
        let candidate = locator(knownLocations: [known]).firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, known.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .knownLocation)
    }

    /// 只装过 wrapper 发行版（没用 Homebrew）时，从 GRADLE_USER_HOME 里找可执行文件。
    func testWrapperDistributionUnderGradleUserHome() throws {
        let gradleUserHome = home.appendingPathComponent(".gradle", isDirectory: true)
        let dist = try makeExecutable(
            gradleUserHome.appendingPathComponent(
                "wrapper/dists/gradle-8.7-bin/abc123/gradle-8.7/bin/gradle"
            )
        )
        let candidate = locator().firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, dist.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .wrapperDistribution)
    }

    /// GRADLE_USER_HOME 环境变量覆盖默认的 ~/.gradle。
    func testGradleUserHomeEnvironmentIsRespected() throws {
        let custom = home.appendingPathComponent("custom-gradle-home", isDirectory: true)
        let dist = try makeExecutable(
            custom.appendingPathComponent("wrapper/dists/gradle-8.7-bin/hash/gradle-8.7/bin/gradle")
        )
        let candidate = locator(environment: [
            "PATH": guiPath,
            "GRADLE_USER_HOME": custom.path,
        ]).firstUsable()
        XCTAssertEqual(candidate?.executable.standardizedFileURL, dist.standardizedFileURL)
        XCTAssertEqual(candidate?.source, .wrapperDistribution)
    }

    func testNothingUsableReturnsNilAndActionableDetail() {
        let locator = locator()
        XCTAssertNil(locator.firstUsable())
        let detail = locator.failureDetail()
        XCTAssertTrue(detail.contains("找不到 Gradle"), detail)
        XCTAssertTrue(detail.contains("项目 gradlew"), detail)
        XCTAssertTrue(detail.contains("brew install gradle"), detail)
    }

    /// 同一个可执行文件不能因为同时在 PATH 和已知位置出现而被重复列出。
    func testAttemptedDeduplicatesSamePath() throws {
        let shared = home.appendingPathComponent("bin/gradle")
        try makeExecutable(shared)
        let attempted = locator(
            environment: ["PATH": shared.deletingLastPathComponent().path],
            knownLocations: [shared]
        ).attempted()
        XCTAssertEqual(attempted.filter { $0.executable.path == shared.path }.count, 1)
    }

    func testDefaultKnownLocationsCoverHomebrewAndSdkman() {
        let locations = GradleLocator.defaultKnownLocations(homeDirectory: home).map(\.path)
        XCTAssertTrue(locations.contains("/opt/homebrew/bin/gradle"))
        XCTAssertTrue(locations.contains("/usr/local/bin/gradle"))
        XCTAssertTrue(locations.contains(home.appendingPathComponent(".sdkman/candidates/gradle/current/bin/gradle").path))
    }
}
