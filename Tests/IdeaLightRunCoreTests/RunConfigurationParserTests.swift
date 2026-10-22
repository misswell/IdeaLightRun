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

    // MARK: - Maven / JUnit（M5）

    func testMavenRunConfigurationNestedSettings() throws {
        let config = try parseSingleRunXML(
            name: "clean-install",
            xml: """
            <configuration name="clean-install" type="MavenRunConfigurationType" factoryName="Maven">
              <MavenSettings>
                <option name="myGeneralSettings">
                  <MavenGeneralSettings>
                    <option name="alwaysUpdateSnapshots" value="true" />
                    <option name="checksumPolicy" value="WARN" />
                    <option name="failureBehavior" value="FAIL_AT_END" />
                    <option name="mavenHome" value="Use Maven wrapper" />
                    <option name="outputLevel" value="DEBUG" />
                    <option name="printErrorStackTraces" value="true" />
                    <option name="threads" value="1C" />
                    <option name="workOffline" value="true" />
                  </MavenGeneralSettings>
                </option>
                <option name="myRunnerSettings">
                  <MavenRunnerSettings>
                    <option name="delegateBuildToMaven" value="false" />
                    <option name="environmentProperties">
                      <map>
                        <entry key="MAVEN_TARGET" value="dev" />
                      </map>
                    </option>
                    <option name="jreName" value="#USE_PROJECT_JDK" />
                    <option name="mavenProperties">
                      <map>
                        <entry key="skipITs" value="true" />
                      </map>
                    </option>
                    <option name="passParentEnv" value="false" />
                    <option name="runMavenInBackground" value="true" />
                    <option name="skipTests" value="true" />
                    <option name="vmOptions" value="-Xmx2g" />
                  </MavenRunnerSettings>
                </option>
                <option name="myRunnerParameters">
                  <MavenRunnerParameters>
                    <option name="cmdOptions" value="-Dfoo=bar" />
                    <option name="goals">
                      <list>
                        <option value="clean" />
                        <option value="install" />
                      </list>
                    </option>
                    <option name="pomFileName" value="pom.xml" />
                    <option name="profiles">
                      <set>
                        <option value="dev" />
                      </set>
                    </option>
                    <option name="profilesMap">
                      <map>
                        <entry key="ci" value="true" />
                        <entry key="off" value="false" />
                      </map>
                    </option>
                    <option name="projectsCmdOptionValues">
                      <list>
                        <option value="app" />
                        <option value="lib" />
                      </list>
                    </option>
                    <option name="resolveToWorkspace" value="true" />
                    <option name="workingDirPath" value="$PROJECT_DIR$/app" />
                  </MavenRunnerParameters>
                </option>
              </MavenSettings>
              <module name="app" />
              <method v="2">
                <option name="Make" enabled="true" />
              </method>
            </configuration>
            """
        )

        XCTAssertEqual(config.type, .maven)
        let options = try XCTUnwrap(config.mavenOptions)
        XCTAssertEqual(options.goals, ["clean", "install"])
        XCTAssertEqual(options.commandLineOptions, "-Dfoo=bar")
        XCTAssertEqual(options.pomFileName, "pom.xml")
        XCTAssertEqual(options.profiles, ["dev", "ci"])
        XCTAssertEqual(options.properties, ["skipITs": "true"])
        XCTAssertEqual(options.environmentVariables, ["MAVEN_TARGET": "dev"])
        XCTAssertEqual(options.vmOptions, "-Xmx2g")
        XCTAssertEqual(options.jreName, "#USE_PROJECT_JDK")
        XCTAssertTrue(options.skipTests)
        XCTAssertTrue(options.updateSnapshots)
        XCTAssertEqual(options.selectedProjects, ["app", "lib"])
        XCTAssertEqual(options.generalArguments, ["-o", "-U", "-T", "1C", "-X", "-c", "-fae", "-e"])
        XCTAssertTrue(options.unsupportedOptions.isEmpty)

        XCTAssertEqual(config.workingDirectory, "$PROJECT_DIR$/app")
        XCTAssertFalse(config.passParentEnvironment)
        XCTAssertEqual(config.environmentVariables["MAVEN_TARGET"], "dev")
        // MavenSettings 是已识别结构，不能落进 rawOptions。
        XCTAssertTrue(config.rawOptions.isEmpty)
    }

    func testMavenRunConfigurationUnsupportedGeneralSettingsFailClosed() throws {
        let config = try parseSingleRunXML(
            name: "custom-maven",
            xml: """
            <configuration name="custom-maven" type="MavenRunConfigurationType">
              <MavenSettings>
                <option name="myGeneralSettings">
                  <MavenGeneralSettings>
                    <option name="mavenHome" value="/opt/apache-maven-3.9.6" />
                    <option name="userSettingsFile" value="/tmp/settings.xml" />
                    <option name="localRepository" value="/tmp/repository" />
                  </MavenGeneralSettings>
                </option>
                <option name="myRunnerParameters">
                  <MavenRunnerParameters>
                    <option name="goals">
                      <list>
                        <option value="validate" />
                      </list>
                    </option>
                    <option name="multimoduleDir" value="services" />
                  </MavenRunnerParameters>
                </option>
              </MavenSettings>
            </configuration>
            """
        )

        let options = try XCTUnwrap(config.mavenOptions)
        XCTAssertEqual(options.goals, ["validate"])
        XCTAssertEqual(
            Set(options.unsupportedOptions),
            ["mavenHome", "userSettingsFile", "localRepository", "multimoduleDir"]
        )
    }

    func testMavenRunConfigurationWithNullSettingsUsesDefaults() throws {
        let config = try parseSingleRunXML(
            name: "defaults",
            xml: """
            <configuration name="defaults" type="MavenRunConfigurationType">
              <MavenSettings>
                <option name="myGeneralSettings" value="null" />
                <option name="myRunnerSettings" value="null" />
                <option name="myRunnerParameters">
                  <MavenRunnerParameters>
                    <option name="goals">
                      <list>
                        <option value="spring-boot:run" />
                      </list>
                    </option>
                  </MavenRunnerParameters>
                </option>
              </MavenSettings>
              <module name="app" />
            </configuration>
            """
        )

        let options = try XCTUnwrap(config.mavenOptions)
        XCTAssertEqual(options.goals, ["spring-boot:run"])
        XCTAssertEqual(options.jreName, "#USE_PROJECT_JDK")
        XCTAssertTrue(options.unsupportedOptions.isEmpty)
        XCTAssertTrue(options.generalArguments.isEmpty)
    }

    /// 真实 IDEA 2020+ 写法：空 PACKAGE_NAME + package = 整个模块。
    func testJUnitPackageTargetWithEmptyPackageMeansWholeModule() throws {
        let config = try parseSingleRunXML(
            name: "All in app",
            xml: """
            <configuration name="All in app" type="JUnit" factoryName="JUnit" temporary="true" nameIsGenerated="true">
              <module name="app" />
              <option name="PACKAGE_NAME" value="" />
              <option name="TEST_OBJECT" value="package" />
              <method v="2">
                <option name="Make" enabled="true" />
              </method>
            </configuration>
            """
        )

        XCTAssertEqual(config.type, .junit)
        XCTAssertEqual(try XCTUnwrap(config.junitOptions).target, .all)
        XCTAssertEqual(config.beforeLaunchTasks, [BeforeLaunchTask(kind: .build, isEnabled: true)])
    }

    func testJUnitMethodTargetAndWorkingDirectory() throws {
        let config = try parseSingleRunXML(
            name: "UserServiceTest",
            xml: """
            <configuration name="UserServiceTest" type="JUnit" factoryName="JUnit">
              <module name="app" />
              <option name="MAIN_CLASS_NAME" value="com.example.UserServiceTest" />
              <option name="METHOD_NAME" value="createsUser" />
              <option name="TEST_OBJECT" value="method" />
              <option name="VM_PARAMETERS" value="-Dspring.profiles.active=test" />
              <option name="WORKING_DIRECTORY" value="file://$PROJECT_DIR$/app" />
              <option name="PASS_PARENT_ENVS" value="false" />
              <envs>
                <env name="DB" value="h2" />
              </envs>
              <method v="2" />
            </configuration>
            """
        )

        let options = try XCTUnwrap(config.junitOptions)
        XCTAssertEqual(options.target, .method(className: "com.example.UserServiceTest", methodName: "createsUser"))
        XCTAssertEqual(config.vmOptions, "-Dspring.profiles.active=test")
        XCTAssertEqual(config.workingDirectory, "file://$PROJECT_DIR$/app")
        XCTAssertFalse(config.passParentEnvironment)
        XCTAssertEqual(config.environmentVariables["DB"], "h2")
    }

    func testJUnitPatternsDirectoryAndTags() throws {
        let patterns = try parseSingleRunXML(
            name: "Patterns",
            xml: """
            <configuration name="Patterns" type="JUnit">
              <module name="app" />
              <option name="TEST_OBJECT" value="pattern" />
              <patterns>
                <pattern testClass="com.example.*Test" />
                <pattern testClass="com.example.UserTest" methodName="createsUser" />
              </patterns>
            </configuration>
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(patterns.junitOptions).target,
            .patterns(["com.example.*Test", "com.example.UserTest#createsUser"])
        )

        let directory = try parseSingleRunXML(
            name: "Directory",
            xml: """
            <configuration name="Directory" type="JUnit">
              <module name="app" />
              <option name="TEST_OBJECT" value="directory" />
              <dir value="$PROJECT_DIR$/app/src/test/java/com/example" />
            </configuration>
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(directory.junitOptions).target,
            .directory("$PROJECT_DIR$/app/src/test/java/com/example")
        )

        let tags = try parseSingleRunXML(
            name: "Tags",
            xml: """
            <configuration name="Tags" type="JUnit">
              <module name="app" />
              <option name="TEST_OBJECT" value="tags" />
              <tags>
                <tag value="slow" />
                <tag value="integration" />
              </tags>
            </configuration>
            """
        )
        XCTAssertEqual(try XCTUnwrap(tags.junitOptions).target, .tags(["slow", "integration"]))
    }

    func testJUnitMissingModuleWarns() throws {
        let config = try parseSingleRunXML(
            name: "NoModule",
            xml: """
            <configuration name="NoModule" type="JUnit">
              <option name="TEST_OBJECT" value="package" />
              <option name="PACKAGE_NAME" value="" />
            </configuration>
            """
        )
        XCTAssertTrue(config.warnings.contains(.missingModule))
    }

    private func parseSingleRunXML(name: String, xml: String) throws -> RunConfiguration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-run-xml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("\(name).run.xml")
        try """
        <component name="ProjectRunConfigurationManager">
        \(xml)
        </component>
        """.write(to: file, atomically: true, encoding: .utf8)
        let configs = try ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun)
        return try XCTUnwrap(configs.first)
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
