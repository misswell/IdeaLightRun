import XCTest
@testable import IdeaLightRunCore

final class BuildSystemDetectorTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
        super.tearDown()
    }

    private func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
        for (name, content) in files {
            try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// settings-only 项目没有根构建脚本：不能把不存在的 build.gradle 当成已检测到。
    func testSettingsOnlyProjectHasNoPhantomBuildFile() throws {
        let root = try makeProject(["settings.gradle": "rootProject.name = 'demo'\ninclude ':app'\n"])
        let detection = BuildSystemDetector.detect(projectRoot: root)

        let gradle = try XCTUnwrap(detection.gradle)
        XCTAssertEqual(gradle.settingsURL, root.appendingPathComponent("settings.gradle"))
        XCTAssertNil(gradle.buildFileURL, "不存在的 build.gradle 不能被当成构建脚本")
        XCTAssertFalse(gradle.usesKotlinDSL)
        XCTAssertTrue(BuildSystemDetector.isValidProjectRoot(root))
    }

    func testSettingsOnlyKotlinDSLProject() throws {
        let root = try makeProject(["settings.gradle.kts": "rootProject.name = \"demo\"\ninclude(\":app\")\n"])
        let detection = BuildSystemDetector.detect(projectRoot: root)

        let gradle = try XCTUnwrap(detection.gradle)
        XCTAssertEqual(gradle.settingsURL, root.appendingPathComponent("settings.gradle.kts"))
        XCTAssertNil(gradle.buildFileURL)
        XCTAssertTrue(gradle.usesKotlinDSL)
        XCTAssertTrue(BuildSystemDetector.isValidProjectRoot(root))
    }

    func testBuildFileOnlyProject() throws {
        let root = try makeProject(["build.gradle": "plugins { id 'java' }\n"])
        let detection = BuildSystemDetector.detect(projectRoot: root)

        let gradle = try XCTUnwrap(detection.gradle)
        XCTAssertNil(gradle.settingsURL)
        XCTAssertEqual(gradle.buildFileURL, root.appendingPathComponent("build.gradle"))
        XCTAssertTrue(BuildSystemDetector.isValidProjectRoot(root))
    }

    func testExistingGradleFixtureStillDetectsBuildFile() throws {
        let root = Fixtures.url("GradleProject")
        let detection = BuildSystemDetector.detect(projectRoot: root)

        let gradle = try XCTUnwrap(detection.gradle)
        XCTAssertEqual(gradle.settingsURL, root.appendingPathComponent("settings.gradle"))
        XCTAssertEqual(gradle.buildFileURL, root.appendingPathComponent("build.gradle"))
    }

    /// 双构建系统项目：两种检测必须同时存在，wrapper 也要分别记录，
    /// 选择哪套由 BuildSystemSelector 统一裁决，检测层不替它做决定。
    func testMavenAndGradleCoexistWithBothWrappers() throws {
        let root = try makeProject([
            "pom.xml": "<project />",
            "mvnw": "#!/bin/sh\n",
            "settings.gradle": "rootProject.name = 'demo'\n",
            "build.gradle": "plugins { id 'java' }\n",
            "gradlew": "#!/bin/sh\n",
        ])
        let detection = BuildSystemDetector.detect(projectRoot: root)

        let maven = try XCTUnwrap(detection.maven)
        XCTAssertEqual(maven.pomURL, root.appendingPathComponent("pom.xml"))
        XCTAssertEqual(maven.wrapperURL, root.appendingPathComponent("mvnw"))

        let gradle = try XCTUnwrap(detection.gradle)
        XCTAssertEqual(gradle.wrapperURL, root.appendingPathComponent("gradlew"))
        XCTAssertEqual(gradle.buildFileURL, root.appendingPathComponent("build.gradle"))
        XCTAssertTrue(BuildSystemDetector.isValidProjectRoot(root))
    }

    /// settings.gradle 里显式映射的 projectDir 优先于按 project path 拼接。
    func testGradleCustomProjectDirectoryMapping() throws {
        let root = try makeProject([
            "settings.gradle": """
            rootProject.name = 'demo'
            include ':app', ':library:util'
            project(':app').projectDir = file('apps/server')
            project(":library:util").projectDir = file("libs/util")
            """,
        ])
        let settingsURL = root.appendingPathComponent("settings.gradle")

        let info = GradleSettingsReader.read(settingsURL: settingsURL)
        XCTAssertEqual(info.projectDirectories[":app"], "apps/server")
        XCTAssertEqual(info.projectDirectories[":library:util"], "libs/util")

        let modules = ModuleResolver.collectModules(projectRoot: root)
        let app = try XCTUnwrap(modules.first { $0.gradlePath == ":app" })
        XCTAssertEqual(app.directory, root.appendingPathComponent("apps/server", isDirectory: true))
        let util = try XCTUnwrap(modules.first { $0.gradlePath == ":library:util" })
        XCTAssertEqual(util.directory, root.appendingPathComponent("libs/util", isDirectory: true))
    }
}
