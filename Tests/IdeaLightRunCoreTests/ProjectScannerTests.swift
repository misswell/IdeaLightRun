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
        XCTAssertEqual(result.diagnostics.count, 1, "只应有重复配置的提示：\(result.diagnostics)")
        XCTAssertEqual(result.diagnostics.first?.severity, .info)
        XCTAssertTrue(result.diagnostics.first?.message.contains("重复") == true)
        XCTAssertNotNil(result.diagnostics.first?.remediation)

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
        XCTAssertEqual(
            ConfigurationCapabilityResolver.resolve(compound, scan: result).readiness,
            .ready,
            "Backend All 的两个成员都可启动"
        )
    }

    /// §10: XML 中途损坏时保留已完整捕获的配置，同时留下可见诊断。
    func testMalformedXMLKeepsPartialConfigurationsAndReportsDiagnostic() throws {
        let root = try makeTemporaryProject(files: [
            ".run/broken.run.xml": """
            <component name="ProjectRunConfigurationManager">
              <configuration default="false" name="Good" type="Application" factoryName="Application">
                <option name="MAIN_CLASS_NAME" value="com.example.Good" />
                <module name="app" />
              </configuration>
              <configuration default="false" name="Broken" type="Application" factoryName="Application">
                <option name="MAIN_CLASS_NAME" value="com.example.Broken" />
            """,
        ])

        let result = try IntelliJProjectScanner().scan(projectRoot: root)

        XCTAssertEqual(result.configurations.map(\.name), ["Good"], "损坏前的配置不能被一起丢掉")
        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.severity, .warning)
        XCTAssertEqual(diagnostic.file.lastPathComponent, "broken.run.xml")
        XCTAssertTrue(diagnostic.message.contains("XML 格式错误"), "实际：\(diagnostic.message)")
        XCTAssertTrue(diagnostic.message.contains("1 个配置"), "实际：\(diagnostic.message)")
    }

    /// 文件读不了要报 error，不能表现得像"项目里没有配置"。
    func testUnreadableConfigurationFileReportsError() throws {
        let root = try makeTemporaryProject(files: [".idea/.keep": ""])
        let runDirectory = root.appendingPathComponent(".run", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runDirectory.appendingPathComponent("ghost.run.xml"),
            withDestinationURL: URL(fileURLWithPath: "/nonexistent/ghost.run.xml")
        )

        let result = try IntelliJProjectScanner().scan(projectRoot: root)

        XCTAssertTrue(result.configurations.isEmpty)
        let diagnostic = try XCTUnwrap(result.diagnostics.first { $0.file.lastPathComponent == "ghost.run.xml" })
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertTrue(diagnostic.message.contains("无法读取"), "实际：\(diagnostic.message)")
    }

    /// §P0-3: 缺字段、不支持的 Before Launch 任务与空 Goal 必须随扫描结果暴露。
    func testMissingFieldsAndUnsupportedTasksProduceDiagnostics() throws {
        let root = try makeTemporaryProject(files: [
            ".run/Incomplete.run.xml": """
            <component name="ProjectRunConfigurationManager">
              <configuration default="false" name="Incomplete" type="Application" factoryName="Application">
                <method v="2">
                  <option name="Gradle.BeforeRunTask" enabled="true" tasks="bootJar" />
                  <option name="Gradle.BeforeRunTask" enabled="true" tasks=" " />
                  <option name="Maven.BeforeRunTask" enabled="true" goal=" " />
                  <option name="ExternalTool" enabled="true" />
                </method>
              </configuration>
            </component>
            """,
        ])

        let result = try IntelliJProjectScanner().scan(projectRoot: root)

        XCTAssertEqual(result.configurations.map(\.name), ["Incomplete"])
        XCTAssertEqual(Set(result.diagnostics.map(\.severity)), [.warning])
        let messages = result.diagnostics.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("缺少 Main Class") }, "实际：\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("Gradle 任务为空") }, "实际：\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("Maven Goal 为空") }, "实际：\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("ExternalTool") }, "实际：\(messages)")
        XCTAssertTrue(result.diagnostics.allSatisfy { !($0.remediation ?? "").isEmpty })
    }

    /// CLI 的 `scan --json` 直接编码 ScanResult：severity 与建议必须能往返。
    func testScanDiagnosticJSONRoundTrip() throws {
        let diagnostic = ScanDiagnostic(
            file: URL(fileURLWithPath: "/tmp/demo/.run/broken.run.xml"),
            severity: .info,
            message: "配置重复",
            remediation: "删除另一份"
        )
        let data = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(ScanDiagnostic.self, from: data)
        XCTAssertEqual(decoded, diagnostic)
    }

    private func makeTemporaryProject(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
