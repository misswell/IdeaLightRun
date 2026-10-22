import XCTest
@testable import IdeaLightRunCore

final class RunConfigurationParserTests: XCTestCase {
    func testSpringBootRunXML() throws {
        let file = Fixtures.url("MavenSingleProject").appendingPathComponent(".run/UserApplication.run.xml")
        let configs = try ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun)

        XCTAssertEqual(configs.count, 1)
        let config = try XCTUnwrap(configs.first)

        XCTAssertEqual(config.name, "UserApplication")
        XCTAssertEqual(config.type, .springBoot)
        XCTAssertEqual(config.readiness, .ready)
        XCTAssertEqual(config.mainClass, "com.example.user.UserApplication")
        XCTAssertEqual(config.moduleName, "idealightrun-demo")
        XCTAssertEqual(config.vmOptions, "-Xms256m -Xmx1024m -Dfile.encoding=UTF-8")
        XCTAssertEqual(config.programArguments, "--spring.profiles.active=dev")
        // 工作目录保留原始宏，展开交给 MacroResolver
        XCTAssertEqual(config.workingDirectory, "$MODULE_WORKING_DIR$")
        XCTAssertEqual(config.environmentVariables["NACOS_ADDR"], "http://localhost:8848")
        XCTAssertEqual(config.environmentVariables["DB_PASSWORD"], "super-secret")
        XCTAssertEqual(config.jreReference, nil)
        XCTAssertEqual(config.source.kind, .dotRun)
        XCTAssertEqual(config.source.file.lastPathComponent, "UserApplication.run.xml")

        // §30: Make → Build
        XCTAssertEqual(config.beforeLaunchTasks, [BeforeLaunchTask(kind: .build, isEnabled: true)])

        // §10: 未知字段进入 rawOptions
        XCTAssertEqual(config.rawOptions["SHORTEN_COMMAND_LINE"], "NONE")
    }

    func testMainClassAlias() throws {
        // MavenMultiProject 的 .run 使用 MAIN_CLASS_NAME，验证 alias 生效
        let file = Fixtures.url("MavenMultiProject").appendingPathComponent(".run/GatewayApplication.run.xml")
        let configs = try ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun)
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.mainClass, "com.example.gateway.GatewayApplication")
        XCTAssertEqual(config.springProfiles, ["dev"])
        XCTAssertEqual(config.workingDirectory, "$PROJECT_DIR$/gateway")
    }

    /// §5: JAR Application 的真实字段名来自 JetBrains JarApplicationConfigurationBean。
    func testJarApplicationRunXML() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-jar-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("StandaloneJar.run.xml")
        try """
        <component name="ProjectRunConfigurationManager">
          <configuration default="false" name="StandaloneJar" type="JarApplicationType" factoryName="Jar Application">
            <option name="JAR_PATH" value="$PROJECT_DIR$/out/standalone.jar" />
            <option name="VM_PARAMETERS" value="-Xmx128m -Dfoo=bar" />
            <option name="PROGRAM_PARAMETERS" value="--port 9090" />
            <option name="WORKING_DIRECTORY" value="$PROJECT_DIR$/work" />
            <option name="ALTERNATIVE_JRE_PATH" value="/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home" />
            <option name="ALTERNATIVE_JRE_PATH_ENABLED" value="true" />
            <envs>
              <env name="MODE" value="jar" />
            </envs>
            <method v="2">
              <option name="BuildArtifacts" enabled="true" />
            </method>
          </configuration>
        </component>
        """.write(to: file, atomically: true, encoding: .utf8)

        let configs = try ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun)
        let config = try XCTUnwrap(configs.first)

        XCTAssertEqual(config.type, .jar)
        XCTAssertEqual(config.jarPath, "$PROJECT_DIR$/out/standalone.jar")
        XCTAssertNil(config.mainClass)
        XCTAssertEqual(config.vmOptions, "-Xmx128m -Dfoo=bar")
        XCTAssertEqual(config.programArguments, "--port 9090")
        XCTAssertEqual(config.workingDirectory, "$PROJECT_DIR$/work")
        XCTAssertEqual(
            config.jreReference,
            "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home"
        )
        XCTAssertEqual(config.environmentVariables["MODE"], "jar")
        XCTAssertTrue(config.beforeLaunchTasks.contains { $0.kind == .unknown(raw: "BuildArtifacts") })
        XCTAssertTrue(config.warnings.contains { warning in
            if case .unsupportedBeforeLaunch = warning { return true }
            return false
        })
    }

    func testJarWithoutPathProducesWarning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-jar-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("NoPath.run.xml")
        try """
        <component name="ProjectRunConfigurationManager">
          <configuration name="NoPath" type="JarApplicationType">
            <option name="VM_PARAMETERS" value="-Xmx64m" />
          </configuration>
        </component>
        """.write(to: file, atomically: true, encoding: .utf8)

        let config = try XCTUnwrap(
            try ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun).first
        )
        XCTAssertEqual(config.type, .jar)
        XCTAssertNil(config.jarPath)
        XCTAssertTrue(config.warnings.contains(.missingJarPath))
    }

    func testCompoundConfiguration() throws {
        let file = Fixtures.url("MavenMultiProject").appendingPathComponent(".run/BackendAll.run.xml")
        let configs = try ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun)
        let config = try XCTUnwrap(configs.first)

        XCTAssertEqual(config.type, .compound)
        XCTAssertEqual(config.compoundMembers.map(\.name), ["GatewayApplication", "UserApplication"])
    }

    func testUnknownTypeIsPreserved() throws {
        let file = Fixtures.url("GradleProject").appendingPathComponent(".run/TomcatLocal.run.xml")
        let configs = try ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun)
        let config = try XCTUnwrap(configs.first)

        XCTAssertEqual(config.type, .unknown("TomcatRunConfigurationType"))
        XCTAssertEqual(config.readiness, .unsupported)
    }

    func testXMLDecodingOfAttributes() throws {
        // workspace 中的 ToolApplication VM 参数含 &quot; 转义
        let file = Fixtures.url("MavenSingleProject").appendingPathComponent(".idea/workspace.xml")
        let configs = try WorkspaceRunConfigurationParser.parse(fileURL: file)
        let tool = try XCTUnwrap(configs.first { $0.name == "ToolApplication" })
        XCTAssertEqual(tool.vmOptions, "-Dname=\"hello world\"")
    }

    func testTypeMapping() {
        XCTAssertEqual(RunConfigurationType.from(ideaType: "Application"), .application)
        XCTAssertEqual(RunConfigurationType.from(ideaType: "SpringBootApplicationConfigurationType"), .springBoot)
        XCTAssertEqual(RunConfigurationType.from(ideaType: "CompoundRunConfigurationType"), .compound)
        XCTAssertEqual(RunConfigurationType.from(ideaType: "JarApplicationType"), .jar)
        XCTAssertEqual(RunConfigurationType.from(ideaType: "MavenRunConfigurationType"), .maven)
        XCTAssertEqual(RunConfigurationType.from(ideaType: "GradleRunConfiguration"), .gradle)
        XCTAssertEqual(RunConfigurationType.from(ideaType: "JUnit"), .junit)
        XCTAssertEqual(RunConfigurationType.from(ideaType: "WhateverType"), .unknown("WhateverType"))
    }
}
