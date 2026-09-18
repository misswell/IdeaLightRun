import XCTest
@testable import IdeaLightRunCore

final class WorkspaceParserTests: XCTestCase {
    func testWorkspaceOnlyParsesRunManagerComponent() throws {
        // workspace.xml 里包含 PropertiesComponent / UsageView 等无关组件，
        // 以及 default="true" 模板，都不应出现在结果中。
        let file = Fixtures.url("MavenSingleProject").appendingPathComponent(".idea/workspace.xml")
        let configs = try WorkspaceRunConfigurationParser.parse(fileURL: file)

        XCTAssertEqual(configs.count, 1)
        let tool = try XCTUnwrap(configs.first)
        XCTAssertEqual(tool.name, "ToolApplication")
        XCTAssertEqual(tool.type, .application)
        XCTAssertEqual(tool.mainClass, "com.example.tool.ToolApplication")
        XCTAssertEqual(tool.moduleName, "idealightrun-demo")
        XCTAssertEqual(tool.source.kind, .workspaceXML)
    }

    func testMultiProjectWorkspace() throws {
        let file = Fixtures.url("MavenMultiProject").appendingPathComponent(".idea/workspace.xml")
        let configs = try WorkspaceRunConfigurationParser.parse(fileURL: file)
        let names = Set(configs.map(\.name))

        XCTAssertEqual(names, ["TenantApplication", "OrphanApp", "GatewayApplication"])

        let tenant = try XCTUnwrap(configs.first { $0.name == "TenantApplication" })
        XCTAssertEqual(tenant.environmentVariables["JSON_ENV"], "{\"a\":1}")
        XCTAssertEqual(tenant.mainClass, "com.example.tenant.TenantApplication")
    }
}
