import XCTest
@testable import IdeaLightRunCore

final class MacroResolverTests: XCTestCase {
    let projectDir = URL(fileURLWithPath: "/tmp/projects/demo", isDirectory: true)
    let moduleDir = URL(fileURLWithPath: "/tmp/projects/demo/gateway", isDirectory: true)

    func makeResolver(environment: [String: String] = [:], moduleDir: URL? = nil) -> MacroResolver {
        MacroResolver(
            projectDir: projectDir,
            workspaceDir: nil,
            moduleDir: moduleDir,
            userHome: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            environment: environment
        )
    }

    func testProjectDirMacro() {
        let result = makeResolver().resolve("$PROJECT_DIR$/lib/x.jar")
        XCTAssertEqual(result.value, "/tmp/projects/demo/lib/x.jar")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testModuleDirMacros() {
        let resolver = makeResolver(moduleDir: moduleDir)
        XCTAssertEqual(resolver.resolve("$MODULE_DIR$/target").value, "/tmp/projects/demo/gateway/target")
        XCTAssertEqual(resolver.resolve("$MODULE_WORKING_DIR$").value, "/tmp/projects/demo/gateway")
    }

    func testWorkspaceDirDefaultsToProjectDir() {
        let result = makeResolver().resolve("$WORKSPACE_DIR$/out")
        XCTAssertEqual(result.value, "/tmp/projects/demo/out")
    }

    func testUserHomeMacro() {
        let result = makeResolver().resolve("$USER_HOME$/.m2/repository")
        XCTAssertEqual(result.value, "/Users/tester/.m2/repository")
    }

    func testMissingModuleDirProducesWarning() {
        let result = makeResolver().resolve("$MODULE_DIR$/target")
        XCTAssertEqual(result.value, "$MODULE_DIR$/target")
        XCTAssertEqual(result.warnings.first?.title, "存在无法解析的变量")
    }

    func testEnvironmentVariableBraces() {
        let result = makeResolver(environment: ["HOME": "/Users/tester", "M2_REPO": "/Users/tester/.m2"])
            .resolve("${M2_REPO}/x.jar")
        XCTAssertEqual(result.value, "/Users/tester/.m2/x.jar")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testEnvironmentVariableDollarForm() {
        let result = makeResolver(environment: ["CUSTOM_VAR": "value"])
            .resolve("-Dconf=$CUSTOM_VAR$/conf")
        XCTAssertEqual(result.value, "-Dconf=value/conf")
    }

    func testUnresolvedEnvironmentVariableWarnsButKeepsLiteral() {
        let result = makeResolver().resolve("-Dconf=$NO_SUCH_VAR$")
        XCTAssertEqual(result.value, "-Dconf=$NO_SUCH_VAR$")
        XCTAssertEqual(result.warnings.count, 1)
        guard case .unresolvedMacro(let token, _)? = result.warnings.first else {
            return XCTFail("期望 unresolvedMacro")
        }
        XCTAssertEqual(token, "$NO_SUCH_VAR$")
    }

    /// §11: 依赖 IDEA 上下文的宏不伪造，产生专用 warning。
    func testIdeaContextMacroWarns() {
        let result = makeResolver().resolve("$Prompt$")
        XCTAssertEqual(result.value, "$Prompt$")
        guard case .ideaContextMacro(let name, _)? = result.warnings.first else {
            return XCTFail("期望 ideaContextMacro")
        }
        XCTAssertEqual(name, "Prompt")
    }

    func testMixedMacros() {
        let result = makeResolver(moduleDir: moduleDir).resolve("$PROJECT_DIR$:$MODULE_DIR$:$USER_HOME$")
        XCTAssertEqual(result.value, "/tmp/projects/demo:/tmp/projects/demo/gateway:/Users/tester")
    }

    func testDollarSignInFilePathNotFooled() {
        // 含 $ 但不是宏形式的文本应原样保留
        let result = makeResolver().resolve("-Dmsg=cost$5")
        XCTAssertEqual(result.value, "-Dmsg=cost$5")
        XCTAssertTrue(result.warnings.isEmpty)
    }
}
