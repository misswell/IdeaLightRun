import XCTest
@testable import IdeaLightRunCore

final class JDKResolverTests: XCTestCase {
    let corretto8 = JDKInstallation(
        home: URL(fileURLWithPath: "/Users/t/Library/Java/JavaVirtualMachines/corretto-1.8.0_462/Contents/Home"),
        majorVersion: 8,
        versionString: "1.8.0_462",
        vendor: "Amazon",
        displayName: "Amazon Corretto 8"
    )
    let zulu8 = JDKInstallation(
        home: URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines/zulu-8.jdk/Contents/Home"),
        majorVersion: 8,
        versionString: "1.8.0_302",
        vendor: "Azul Systems, Inc.",
        displayName: "Zulu 8.56.0.23"
    )
    let openjdk17 = JDKInstallation(
        home: URL(fileURLWithPath: "/Users/t/Library/Java/JavaVirtualMachines/openjdk-17.0.2/Contents/Home"),
        majorVersion: 17,
        versionString: "17.0.2",
        vendor: "Oracle Corporation",
        displayName: "OpenJDK 17.0.2"
    )

    // MARK: - 名字 → major version

    func testMajorVersionFromName() {
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "1.8"), 8)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "8"), 8)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "jdk8"), 8)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "JDK 1.8"), 8)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "Temurin-8"), 8)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "Corretto-8"), 8)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "Zulu-8"), 8)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "17"), 17)
        XCTAssertEqual(JDKResolver.majorVersion(fromName: "21"), 21)
        XCTAssertNil(JDKResolver.majorVersion(fromName: "no-digits"))
    }

    func testMajorVersionFromVersionString() {
        XCTAssertEqual(SystemJDCLocator.majorVersion(fromVersionString: "1.8.0_462"), 8)
        XCTAssertEqual(SystemJDCLocator.majorVersion(fromVersionString: "17.0.2"), 17)
        XCTAssertEqual(SystemJDCLocator.majorVersion(fromVersionString: "11.0.20"), 11)
        XCTAssertEqual(SystemJDCLocator.majorVersion(fromVersionString: "8"), 8)
    }

    // MARK: - java_home 输出解析

    func testParseJavaHomeOutput() {
        let output = """
        Matching Java Virtual Machines (3):
            17.0.2 (arm64) "Oracle Corporation" - "OpenJDK 17.0.2" /Users/t/Library/Java/JavaVirtualMachines/openjdk-17.0.2/Contents/Home
            1.8.421.09 (arm64) "Oracle Corporation" - "Java" /Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home
            1.8.0_462 (arm64) "Amazon" - "Amazon Corretto 8" /Users/t/Library/Java/JavaVirtualMachines/corretto-1.8.0_462/Contents/Home

        """
        let jdks = SystemJDCLocator.parseJavaHomeOutput(output)
        // Internet Plug-Ins 的 Applet JRE 不是可用 JDK，应被过滤
        XCTAssertEqual(jdks.count, 2)
        XCTAssertEqual(jdks[0].majorVersion, 17)
        XCTAssertEqual(jdks[0].vendor, "Oracle Corporation")
        XCTAssertEqual(jdks[1].majorVersion, 8)
        XCTAssertEqual(jdks[1].versionString, "1.8.0_462")
        XCTAssertTrue(jdks[1].home.path.hasSuffix("corretto-1.8.0_462/Contents/Home"))
    }

    // MARK: - 解析优先级（§23）

    func testConfigJDKHasHighestPriority() {
        let resolution = JDKResolver().resolve(
            configJDKName: "1.8",
            projectJDKName: "17",
            candidates: [openjdk17, corretto8, zulu8]
        )
        XCTAssertEqual(resolution.installation, corretto8)
        XCTAssertEqual(resolution.origin, .runConfigurationSpecified)
        XCTAssertEqual(resolution.requiredName, "1.8")
    }

    func testProjectSDKFallback() {
        let resolution = JDKResolver().resolve(
            configJDKName: nil,
            projectJDKName: "17",
            candidates: [corretto8, openjdk17]
        )
        XCTAssertEqual(resolution.installation, openjdk17)
        XCTAssertEqual(resolution.origin, .projectSDK)
    }

    func testUnmatchedProjectSDKWarns() {
        let resolution = JDKResolver().resolve(
            configJDKName: nil,
            projectJDKName: "9",
            candidates: [corretto8, openjdk17]
        )
        XCTAssertNil(resolution.installation)
        XCTAssertEqual(resolution.requiredName, "9")
        XCTAssertFalse(resolution.warnings.isEmpty)
    }

    func testJavaHomeFallback() throws {
        // 构造一个带 bin/java 的临时目录作为 JAVA_HOME
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("idealightrun-jdk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempHome.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: tempHome.appendingPathComponent("bin/java").path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let resolution = JDKResolver().resolve(
            configJDKName: nil,
            projectJDKName: nil,
            candidates: [],
            javaHomePath: tempHome.path,
            environment: [:]
        )
        XCTAssertEqual(resolution.installation?.home.path, tempHome.standardizedFileURL.path)
        XCTAssertEqual(resolution.origin, .javaHome)
    }

    func testSystemInstalledFallbackPicksHighestMajor() {
        let resolution = JDKResolver().resolve(
            configJDKName: nil,
            projectJDKName: nil,
            candidates: [corretto8, zulu8, openjdk17],
            javaHomePath: nil,
            environment: [:]
        )
        XCTAssertEqual(resolution.installation, openjdk17)
        XCTAssertEqual(resolution.origin, .systemInstalled)
    }

    func testNoJDKAtAll() {
        let resolution = JDKResolver().resolve(
            configJDKName: nil,
            projectJDKName: nil,
            candidates: [],
            javaHomePath: nil,
            environment: [:]
        )
        XCTAssertNil(resolution.installation)
        XCTAssertEqual(resolution.origin, .notResolved)
    }

    // MARK: - misc.xml

    func testReadProjectSDKFromMiscXML() throws {
        let sdk = IntelliJSDKReader.readProjectSDK(projectRoot: Fixtures.url("MavenSingleProject"))
        let result = try XCTUnwrap(sdk)
        XCTAssertEqual(result.name, "1.8")
        XCTAssertEqual(result.type, "JavaSDK")

        // Gradle 项目
        let gradleSDK = IntelliJSDKReader.readProjectSDK(projectRoot: Fixtures.url("GradleProject"))
        XCTAssertEqual(gradleSDK?.name, "17")
    }
}
