import XCTest
@testable import IdeaLightRunCore

/// §五: 宏解析集中到 RunConfigurationResolver，warning 不再随 `.value` 被丢掉；
/// 依赖 IDEA 运行期上下文的宏必须禁止启动。
final class MacroResolutionTests: XCTestCase {
    private var projectRoot: URL { Fixtures.url("MavenSingleProject") }
    /// 单模块项目的 module 目录就是根目录（必须是真实存在的目录，
    /// Working Directory 不存在会在解析阶段先报错）。
    private var moduleDir: URL { projectRoot }
    private var module: ProjectModule { ProjectModule(name: "idealightrun-demo", directory: moduleDir) }

    private func makeConfig(
        name: String = "Macro",
        mainClass: String? = "com.example.user.UserApplication",
        vmOptions: String? = nil,
        programArguments: String? = nil,
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = [:],
        environmentFiles: [String] = [],
        passParentEnvironment: Bool = true,
        springProfiles: [String] = [],
        warnings: [ConfigurationWarning] = []
    ) -> RunConfiguration {
        RunConfiguration(
            name: name,
            type: .application,
            mainClass: mainClass,
            moduleName: module.name,
            vmOptions: vmOptions,
            programArguments: programArguments,
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables,
            environmentFiles: environmentFiles,
            passParentEnvironment: passParentEnvironment,
            springProfiles: springProfiles,
            source: ConfigurationSource(kind: .dotRun, file: projectRoot.appendingPathComponent("x.run.xml"), modifiedAt: nil),
            warnings: warnings
        )
    }

    private func resolve(
        _ config: RunConfiguration,
        parentEnvironment: [String: String] = ["HOME": "/home/tester"]
    ) throws -> ResolvedRunConfiguration {
        try RunConfigurationResolver().resolve(
            config: config,
            projectRoot: projectRoot,
            module: module,
            jdk: nil,
            parentEnvironment: parentEnvironment
        )
    }

    // MARK: - 正常宏必须安静

    func testStandardMacrosResolveWithoutWarnings() throws {
        let resolved = try resolve(makeConfig(
            vmOptions: "-Dapp.home=$PROJECT_DIR$",
            workingDirectory: "$MODULE_DIR$"
        ))
        XCTAssertEqual(resolved.vmArguments, ["-Dapp.home=\(projectRoot.path)"])
        XCTAssertEqual(resolved.workingDirectory.path, moduleDir.path)
        XCTAssertTrue(resolved.warnings.isEmpty, "已支持的宏不该产生告警：\(resolved.warnings)")
    }

    /// §五 的核心回归：以前 `resolver.resolve(x).value` 把 warnings 丢了，
    /// 现在它们必须出现在解析结果里（GUI/日志才看得见）。
    func testConfigurationWarningsArePreserved() throws {
        let carried = ConfigurationWarning.missingModule
        let resolved = try resolve(makeConfig(warnings: [carried]))
        XCTAssertTrue(resolved.warnings.contains(carried))
    }

    /// Spring 占位符（`${random.value}`）不是 IDEA 宏：留原文照常启动，不告警也不拦。
    func testSpringPlaceholderDoesNotBlockLaunch() throws {
        let resolved = try resolve(makeConfig(vmOptions: "-Dseed=${random.value}"))
        XCTAssertEqual(resolved.vmArguments, ["-Dseed=${random.value}"])
        XCTAssertTrue(resolved.warnings.isEmpty, "Spring 占位符不该被当成 IDEA 宏：\(resolved.warnings)")
    }

    /// `${...}` 形式的环境变量引用取不到值时：告警保留原文，但不禁止启动。
    func testUnresolvedEnvironmentReferenceWarnsButStillLaunches() throws {
        let resolved = try resolve(makeConfig(vmOptions: "-Dseed=${NOT_SET_IN_TEST_ENV}"))
        XCTAssertEqual(resolved.vmArguments, ["-Dseed=${NOT_SET_IN_TEST_ENV}"])
        XCTAssertTrue(
            resolved.warnings.contains { warning in
                if case .unresolvedMacro(let token, _) = warning { return token == "${NOT_SET_IN_TEST_ENV}" }
                return false
            },
            "占位符要留告警：\(resolved.warnings)"
        )
    }

    // MARK: - 依赖 IDEA 上下文的宏：禁止启动

    func testPromptMacroForbidsLaunch() {
        XCTAssertThrowsError(try resolve(makeConfig(vmOptions: "-Dx=$Prompt$"))) { error in
            guard let error = error as? IdeaLightRunError,
                  case .unresolvedIdeaContextMacro(let detail) = error else {
                return XCTFail("期望 unresolvedIdeaContextMacro，实际：\(error)")
            }
            XCTAssertEqual(error.title, "配置依赖 IDEA 当前上下文")
            XCTAssertTrue(detail.contains("$Prompt$"))
            XCTAssertTrue(detail.contains("Macro"), "错误里要带上配置名：\(detail)")
        }
    }

    func testFilePathAndSelectedTextMacrosForbidLaunch() {
        for token in ["$FilePath$", "$SelectedText$"] {
            XCTAssertThrowsError(
                try resolve(makeConfig(programArguments: token)),
                "\(token) 应禁止启动"
            ) { error in
                guard case IdeaLightRunError.unresolvedIdeaContextMacro? = error as? IdeaLightRunError else {
                    return XCTFail("实际：\(error)")
                }
            }
        }
    }

    /// `$UPPER_CASE$` 形状的未知宏是 IDEA 宏，不能带着原文启动。
    func testUnknownUpperMacroForbidsLaunch() {
        XCTAssertThrowsError(try resolve(makeConfig(mainClass: "com.example.$CUSTOM_PKG$App"))) { error in
            guard let error = error as? IdeaLightRunError,
                  case .unresolvedMacro(let detail) = error else {
                return XCTFail("期望 unresolvedMacro，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("$CUSTOM_PKG$"))
        }
    }

    // MARK: - 分词与注入

    func testVMOptionsKeepQuotedValuesAsOneArgument() throws {
        let resolved = try resolve(makeConfig(vmOptions: "-Dname=\"hello world\" -Xmx256m"))
        XCTAssertEqual(resolved.vmArguments, ["-Dname=hello world", "-Xmx256m"])
    }

    func testSpringProfilesInjectedOnce() throws {
        XCTAssertEqual(
            try resolve(makeConfig(springProfiles: ["dev", "local"])).vmArguments,
            ["-Dspring.profiles.active=dev,local"]
        )
        let explicit = try resolve(makeConfig(
            vmOptions: "-Dspring.profiles.active=prod",
            springProfiles: ["dev"]
        ))
        XCTAssertEqual(explicit.vmArguments, ["-Dspring.profiles.active=prod"], "已显式给出时不重复注入")
    }

    // MARK: - 环境变量与工作目录

    func testEnvironmentPrecedenceAndParentFlagReachThePlan() throws {
        let parent = ["HOME": "/home/tester", "PATH": "/usr/bin", "DB_PASSWORD": "from-system"]
        let inherited = try resolve(
            makeConfig(environmentVariables: ["MINE": "1"]),
            parentEnvironment: parent
        )
        XCTAssertEqual(inherited.environment["PATH"], "/usr/bin")
        XCTAssertEqual(inherited.environment["DB_PASSWORD"], "from-system")

        let isolated = try resolve(
            makeConfig(environmentVariables: ["MINE": "1"], passParentEnvironment: false),
            parentEnvironment: parent
        )
        XCTAssertNil(isolated.environment["PATH"])
        XCTAssertEqual(isolated.environment["MINE"], "1")
    }

    func testEnvironmentFilesAreLoadedAndReportedByPath() throws {
        let envProject = Fixtures.url("EnvironmentFileProject")
        let resolved = try RunConfigurationResolver().resolve(
            config: RunConfiguration(
                name: "EnvFiles",
                type: .application,
                mainClass: "com.example.env.EnvApplication",
                environmentVariables: ["DB_PASSWORD": "from-run-configuration"],
                environmentFiles: ["$PROJECT_DIR$/.env"],
                passParentEnvironment: false,
                source: ConfigurationSource(kind: .dotRun, file: envProject.appendingPathComponent("x.run.xml"), modifiedAt: nil)
            ),
            projectRoot: envProject,
            module: nil,
            parentEnvironment: [:]
        )
        // §17: 只报路径，不报内容
        XCTAssertEqual(resolved.loadedEnvironmentFiles, [envProject.appendingPathComponent(".env").path])
        XCTAssertEqual(resolved.environment["DB_PASSWORD"], "from-run-configuration")
        XCTAssertEqual(resolved.environment["SPRING_PROFILES_ACTIVE"], "dev")
    }

    func testMissingWorkingDirectoryReportsOriginalValue() {
        let config = makeConfig(workingDirectory: "$PROJECT_DIR$/does-not-exist")
        XCTAssertThrowsError(try resolve(config)) { error in
            guard let error = error as? IdeaLightRunError,
                  case .launchFailed(let detail) = error else {
                return XCTFail("期望 launchFailed，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("does-not-exist"))
            XCTAssertTrue(detail.contains("$PROJECT_DIR$"), "错误里要保留未展开的原始值：\(detail)")
        }
    }
}
