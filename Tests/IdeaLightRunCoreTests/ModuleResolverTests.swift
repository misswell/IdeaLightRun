import XCTest
@testable import IdeaLightRunCore

final class ModuleResolverTests: XCTestCase {
    let multiRoot = Fixtures.url("MavenMultiProject")
    lazy var multiModules = ModuleResolver.collectModules(projectRoot: multiRoot)

    func testResolveByName() throws {
        let resolution = ModuleResolver.resolveModule(
            named: "gateway", mainClass: nil, projectRoot: multiRoot, knownModules: multiModules
        )
        let module = try XCTUnwrap(resolution.module)
        XCTAssertEqual(module.directory.lastPathComponent, "gateway")
        XCTAssertEqual(module.imlURL?.lastPathComponent, "gateway.iml")
        XCTAssertEqual(resolution.method, .byName)
        XCTAssertTrue(resolution.warnings.isEmpty)
    }

    func testResolveByMavenArtifactIdCoordinate() throws {
        let resolution = ModuleResolver.resolveModule(
            named: "com.example:user-service", mainClass: nil, projectRoot: multiRoot, knownModules: multiModules
        )
        let module = try XCTUnwrap(resolution.module)
        XCTAssertEqual(module.directory.lastPathComponent, "user-service")
        XCTAssertEqual(resolution.method, .byArtifactId)
    }

    /// §13 方式五：module 名解析失败时根据 mainClass 定位
    func testResolveByMainClassFallback() throws {
        let resolution = ModuleResolver.resolveModule(
            named: "ghost",
            mainClass: "com.example.tenant.TenantApplication",
            projectRoot: multiRoot,
            knownModules: multiModules
        )
        let module = try XCTUnwrap(resolution.module)
        XCTAssertEqual(module.directory.lastPathComponent, "tenant")
        XCTAssertEqual(resolution.method, .byMainClassFallback)
        XCTAssertEqual(resolution.warnings.first?.title, "找不到对应 Module")
    }

    func testResolveWithoutModuleNameUsesMainClass() throws {
        let resolution = ModuleResolver.resolveModule(
            named: nil,
            mainClass: "com.example.user.UserApplication",
            projectRoot: multiRoot,
            knownModules: multiModules
        )
        let module = try XCTUnwrap(resolution.module)
        XCTAssertEqual(module.directory.lastPathComponent, "user-service")
        XCTAssertEqual(resolution.method, .byMainClassFallback)
        XCTAssertTrue(resolution.warnings.isEmpty)
    }

    func testUnresolvableModule() {
        let resolution = ModuleResolver.resolveModule(
            named: "nope", mainClass: nil, projectRoot: multiRoot, knownModules: multiModules
        )
        XCTAssertNil(resolution.module)
        XCTAssertEqual(resolution.method, .notResolved)
        XCTAssertFalse(resolution.warnings.isEmpty)
    }

    func testGradleModuleNameResolution() throws {
        let gradleRoot = Fixtures.url("GradleProject")
        let modules = ModuleResolver.collectModules(projectRoot: gradleRoot)
        let resolution = ModuleResolver.resolveModule(
            named: "app", mainClass: nil, projectRoot: gradleRoot, knownModules: modules
        )
        let module = try XCTUnwrap(resolution.module)
        XCTAssertEqual(module.directory.lastPathComponent, "app")
        XCTAssertEqual(module.gradlePath, ":app")
    }

    func testMavenReactorCollection() {
        let infos = MavenPomReader.collectReactor(rootPom: multiRoot.appendingPathComponent("pom.xml"))
        let artifacts = Set(infos.map(\.artifactId))
        XCTAssertEqual(artifacts, ["demo-root", "common", "user-service", "gateway", "tenant"])
        let common = try? XCTUnwrap(infos.first { $0.artifactId == "common" })
        XCTAssertEqual(common?.groupId, "com.example")
        XCTAssertEqual(common?.packaging, "jar")
    }

    func testIdeaFileURLResolution() {
        let projectRoot = URL(fileURLWithPath: "/Users/t/My Project", isDirectory: true)
        let url = ModuleResolver.resolveIdeaFileURL(
            "file://$PROJECT_DIR$/gateway/gateway.iml",
            projectRoot: projectRoot,
            moduleDir: projectRoot
        )
        XCTAssertEqual(url?.path, "/Users/t/My Project/gateway/gateway.iml")
    }
}
