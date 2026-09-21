import XCTest
@testable import IdeaLightRunCore

/// §4.1: 环境变量优先级 System Environment < Env File 1 < Env File 2 < … < Run Configuration。
final class EnvironmentResolverTests: XCTestCase {
    private var fixture: URL { Fixtures.url("EnvironmentFileProject") }
    private var macros: MacroResolver { MacroResolver(projectDir: fixture) }

    private func envFile(_ name: String) -> String {
        fixture.appendingPathComponent(name).path
    }

    func testFixtureFilesArePartOfTheRepository() throws {
        // fixture 里的 .env 若被 .gitignore 吃掉，CI 上这组测试会静默失去意义。
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFile(".env")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFile(".env.local")))
    }

    func testPrecedenceAcrossAllSources() throws {
        let parent = ["PATH": "/usr/bin", "HOME": "/home/tester", "DB_PASSWORD": "from-system"]
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: true,
            environmentFiles: [envFile(".env"), envFile(".env.local")],
            environmentVariables: ["DB_PASSWORD": "from-run-configuration"],
            macros: macros,
            parentEnvironment: parent
        )
        // ① Run Configuration 显式变量最高
        XCTAssertEqual(resolved.values["DB_PASSWORD"], "from-run-configuration")
        // ② 后面的 env file 覆盖前面的
        XCTAssertEqual(resolved.values["LOCAL_ONLY"], "yes")
        // ③ 父进程环境保留
        XCTAssertEqual(resolved.values["PATH"], "/usr/bin")
        XCTAssertEqual(resolved.loadedFiles, [envFile(".env"), envFile(".env.local")])
    }

    func testEnvFileOrderOverridesSystemEnvironment() throws {
        let parent = ["DB_PASSWORD": "from-system", "HOME": "/home/tester"]
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: true,
            environmentFiles: [envFile(".env")],
            environmentVariables: [:],
            macros: macros,
            parentEnvironment: parent
        )
        XCTAssertEqual(resolved.values["DB_PASSWORD"], "super secret")
    }

    func testSecondEnvFileOverridesFirst() throws {
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: true,
            environmentFiles: [envFile(".env"), envFile(".env.local")],
            environmentVariables: [:],
            macros: macros,
            parentEnvironment: [:]
        )
        XCTAssertEqual(resolved.values["DB_PASSWORD"], "overridden by local")
    }

    /// §4.1: PASS_PARENT_ENVS=false 时不继承完整父进程环境，只留最小集合。
    func testPassParentEnvironmentFalseKeepsOnlyMinimalSet() throws {
        let parent = [
            "PATH": "/usr/bin", "HOME": "/home/tester", "TMPDIR": "/tmp/x",
            "SECRET_TOKEN": "leak-me", "JAVA_HOME": "/jdk/17",
        ]
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: false,
            environmentFiles: [],
            environmentVariables: ["MINE": "1"],
            macros: macros,
            parentEnvironment: parent
        )
        XCTAssertEqual(resolved.values["HOME"], "/home/tester")
        XCTAssertEqual(resolved.values["TMPDIR"], "/tmp/x")
        XCTAssertNil(resolved.values["PATH"])
        XCTAssertNil(resolved.values["SECRET_TOKEN"])
        XCTAssertNil(resolved.values["JAVA_HOME"])
        XCTAssertEqual(resolved.values["MINE"], "1")
        XCTAssertEqual(Set(resolved.values.keys), Set(["HOME", "TMPDIR", "MINE"]))
    }

    func testDotEnvSemanticsThroughRealFiles() throws {
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: false,
            environmentFiles: [envFile(".env")],
            environmentVariables: [:],
            macros: macros,
            parentEnvironment: [:]
        )
        XCTAssertEqual(resolved.values["SPRING_PROFILES_ACTIVE"], "dev")
        // export 前缀与双引号带空格
        XCTAssertEqual(resolved.values["DB_PASSWORD"], "super secret")
        // 单引号字面量：$NOT_EXPANDED 不该被展开
        XCTAssertEqual(resolved.values["SINGLE_QUOTED"], "literal $NOT_EXPANDED")
        // 同文件内前向引用展开
        XCTAssertEqual(resolved.values["PATH_LIKE"], "/opt/bin:dev")
        // 行内注释被切掉
        XCTAssertEqual(resolved.values["INLINE"], "keep")
        // 未定义的引用保留原文
        XCTAssertEqual(resolved.values["UNEXPANDED"], "${MISSING_VAR}")
        XCTAssertEqual(resolved.values["EMPTY_VALUE"], "")
    }

    /// §5: env 文件路径走宏解析，$PROJECT_DIR$ 要能落地的。
    func testEnvFilePathGoesThroughMacroResolver() throws {
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: false,
            environmentFiles: ["$PROJECT_DIR$/.env"],
            environmentVariables: [:],
            macros: macros,
            parentEnvironment: [:]
        )
        XCTAssertEqual(resolved.loadedFiles, [envFile(".env")])
    }

    /// §21: 缺文件必须显式报错，不能静默少一份环境。
    func testMissingEnvironmentFileThrows() {
        XCTAssertThrowsError(try EnvironmentResolver.resolve(
            passParentEnvironment: false,
            environmentFiles: ["$PROJECT_DIR$/.env.missing"],
            environmentVariables: [:],
            macros: macros,
            parentEnvironment: [:]
        )) { error in
            guard case IdeaLightRunError.environmentFileNotFound(let path)? = error as? IdeaLightRunError else {
                return XCTFail("期望 environmentFileNotFound，实际：\(error)")
            }
            XCTAssertTrue(path.hasSuffix(".env.missing"), "错误里要带上找不到的路径")
            XCTAssertEqual((error as? IdeaLightRunError)?.title, "Environment File 不存在")
        }
    }

    /// §17: 解析结果与告警里都不能出现 env 文件的值。
    func testSecretsDoNotLeakIntoWarnings() throws {
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: false,
            environmentFiles: [envFile(".env")],
            environmentVariables: ["TOKEN": "secret-value"],
            macros: macros,
            parentEnvironment: [:]
        )
        let dump = resolved.warnings.map { "\($0.title)\($0.detail)" }.joined()
        XCTAssertFalse(dump.contains("secret-value"))
        XCTAssertFalse(dump.contains("super secret"))
    }

    /// 配置里的 env 值同样经过宏解析（IDEA 允许写 $PROJECT_DIR$ 之类的值）。
    func testRunConfigurationValuesResolveMacros() throws {
        let resolved = try EnvironmentResolver.resolve(
            passParentEnvironment: false,
            environmentFiles: [],
            environmentVariables: ["APP_HOME": "$PROJECT_DIR$/app"],
            macros: macros,
            parentEnvironment: [:]
        )
        XCTAssertEqual(resolved.values["APP_HOME"], fixture.appendingPathComponent("app").path)
    }
}
