import XCTest
@testable import IdeaLightRunCore

final class ProjectScannerTests: XCTestCase {
    func testScanMavenMultiProject() throws {
        let projectRoot = Fixtures.url("MavenMultiProject")
        let result = try IntelliJProjectScanner().scan(projectRoot: projectRoot)

        let names = Set(result.configurations.map(\.name))
        // .run 两条 + runConfigurations 一条 + workspace 三条（Gateway 重复 → 去重）+ 深度 4 的 DeepConfig
        XCTAssertEqual(names, ["GatewayApplication", "Backend All", "UserApplication", "TenantApplication", "OrphanApp", "DeepConfig"])
        XCTAssertEqual(result.ignoredDuplicateCount, 1)

        // §7: .run/*.run.xml 优先级高于 workspace.xml
        let gateway = try XCTUnwrap(result.configurations.first { $0.name == "GatewayApplication" })
        XCTAssertEqual(gateway.source.kind, .dotRun)
        XCTAssertEqual(gateway.vmOptions, "-Xms256m -Xmx1024m")

        // 构建系统检测
        XCTAssertNotNil(result.buildSystem.maven)
        XCTAssertEqual(result.buildSystem.maven?.wrapperURL, nil)
        XCTAssertNil(result.buildSystem.gradle)

        // §23: project JDK
        XCTAssertEqual(result.projectJDKName, "1.8")

        // 模块收集：iml 三个 + tenant 走 Maven reactor（根 pom 的 demo-root 也是 reactor 成员）
        let moduleNames = Set(result.modules.map(\.name))
        XCTAssertEqual(moduleNames, ["gateway", "user-service", "common", "tenant", "demo-root"])
        let tenantModule = try XCTUnwrap(result.modules.first { $0.name == "tenant" })
        XCTAssertEqual(tenantModule.directory.lastPathComponent, "tenant")
        XCTAssertEqual(tenantModule.artifactId, "tenant")
    }

    func testScanMavenSingleProject() throws {
        let projectRoot = Fixtures.url("MavenSingleProject")
        let result = try IntelliJProjectScanner().scan(projectRoot: projectRoot)

        let names = Set(result.configurations.map(\.name))
        XCTAssertEqual(names, ["UserApplication", "ToolApplication"])

        let user = try XCTUnwrap(result.configurations.first { $0.name == "UserApplication" })
        XCTAssertEqual(user.type, .springBoot)

        let tool = try XCTUnwrap(result.configurations.first { $0.name == "ToolApplication" })
        XCTAssertEqual(tool.type, .application)
        XCTAssertEqual(tool.source.kind, .workspaceXML)
    }

    func testScanGradleProject() throws {
        let projectRoot = Fixtures.url("GradleProject")
        let result = try IntelliJProjectScanner().scan(projectRoot: projectRoot)

        let names = Set(result.configurations.map(\.name))
        XCTAssertEqual(names, ["AppApplication", "Tomcat Local"])

        // §78: 未支持类型仍然展示，不隐藏
        let tomcat = try XCTUnwrap(result.configurations.first { $0.name == "Tomcat Local" })
        XCTAssertEqual(tomcat.type, .unknown("TomcatRunConfigurationType"))
        XCTAssertEqual(tomcat.readiness, .unsupported)

        XCTAssertNil(result.buildSystem.maven)
        XCTAssertNotNil(result.buildSystem.gradle)
        XCTAssertEqual(result.projectJDKName, "17")

        // 方式四：Gradle settings 名称匹配
        let moduleNames = Set(result.modules.map(\.name))
        XCTAssertEqual(moduleNames, ["gradle-demo", "app", "util"])
    }

    /// §6: 递归 *.run.xml 深度上限 4，忽略 target 等目录
    func testScanDepthAndIgnoredDirectories() throws {
        let projectRoot = Fixtures.url("MavenMultiProject")
        let result = try IntelliJProjectScanner().scan(projectRoot: projectRoot)
        let names = Set(result.configurations.map(\.name))

        XCTAssertTrue(names.contains("DeepConfig"), "深度 4 的 .run.xml 应被收录")
        XCTAssertFalse(names.contains("TooDeep"), "深度 5 的 .run.xml 不应被收录")
        XCTAssertFalse(names.contains("Junk"), "target/ 下的 .run.xml 不应被收录")
    }

    func testScanMissingDirectoryThrows() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-exists-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try IntelliJProjectScanner().scan(projectRoot: missing)) { error in
            guard case IdeaLightRunError.projectNotFound = error else {
                return XCTFail("期望 projectNotFound，实际：\(error)")
            }
        }
    }

    func testCompoundReadyState() throws {
        let result = try IntelliJProjectScanner().scan(projectRoot: Fixtures.url("MavenMultiProject"))
        let compound = try XCTUnwrap(result.configurations.first { $0.name == "Backend All" })
        XCTAssertEqual(compound.type, .compound)
        XCTAssertEqual(compound.readiness, .planned)
    }
}
