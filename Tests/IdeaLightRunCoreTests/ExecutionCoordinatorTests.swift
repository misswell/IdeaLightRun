import XCTest
@testable import IdeaLightRunCore

/// §8/§22/§23: `ExecutionCoordinator` 是 GUI 与 CLI 唯一的启动入口，
/// 「这个配置能不能跑」也只在这里判断。界面侧不许复制一份 `if SpringBoot`，
/// 所以门禁必须排在扫盘、定位 Maven、解析 JDK 之前，并且与 `supportLevel` 同源。
final class ExecutionCoordinatorTests: XCTestCase {
    private func config(_ type: RunConfigurationType, name: String = "SomeConfig") -> RunConfiguration {
        RunConfiguration(
            name: name,
            type: type,
            mainClass: "com.example.App",
            source: ConfigurationSource(
                kind: .dotRun,
                file: URL(fileURLWithPath: "/tmp/\(name).run.xml"),
                modifiedAt: nil
            )
        )
    }

    // MARK: - 门禁范围

    func testApplicationAndSpringBootPassTheGate() throws {
        XCTAssertNoThrow(try ExecutionCoordinator.ensureRunnable(config(.application)))
        XCTAssertNoThrow(try ExecutionCoordinator.ensureRunnable(config(.springBoot)))
    }

    /// 其余类型一律明确拒绝，且说清是哪个配置的哪种类型（§24 约束 8：不许静默跳过）。
    func testOtherTypesAreRejectedWithReason() {
        let rejected: [(RunConfigurationType, String)] = [
            (.jar, "JAR"),
            (.maven, "Maven"),
            (.gradle, "Gradle"),
            (.compound, "Compound"),
            (.junit, "JUnit"),
            (.unknown("TestNG"), "TestNG"),
        ]
        for (type, displayName) in rejected {
            XCTAssertThrowsError(try ExecutionCoordinator.ensureRunnable(config(type, name: "Cfg-\(displayName)"))) { error in
                guard case IdeaLightRunError.unsupportedConfiguration(let detail) = error else {
                    return XCTFail("\(type)：期望 unsupportedConfiguration，实际 \(error)")
                }
                XCTAssertTrue(detail.contains("Cfg-\(displayName)"), detail)
                XCTAssertTrue(detail.contains(displayName), detail)
                XCTAssertTrue(detail.contains("Application"), detail)
            }
        }
    }

    /// 门禁与界面徽标同源：`supportLevel == .supported` 的集合与放行的集合一致，
    /// 不会出现「行内说 Ready、点了被拦」或反之。
    func testGateAgreesWithSupportLevelBadge() {
        let all: [RunConfigurationType] = [
            .application, .springBoot, .jar, .maven, .gradle, .compound, .junit, .unknown("X"),
        ]
        for type in all {
            let passes = (try? ExecutionCoordinator.ensureRunnable(config(type))) != nil
            XCTAssertEqual(passes, type.supportLevel == .supported, "\(type)")
        }
    }

    // MARK: - 门禁排在最前

    /// 项目根不存在（连扫描都会失败）时，不支持的配置仍然先落到 unsupportedConfiguration：
    /// 说明判断发生在 Core 的最前面，GUI / CLI 无从绕过，也不会先弹一堆构建错误。
    func testGateFiresBeforeProjectDiscovery() async throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-gate-\(UUID().uuidString)", isDirectory: true)
        let coordinator = ExecutionCoordinator()
        do {
            _ = try await coordinator.prepare(
                config: config(.junit, name: "Tests"),
                projectRoot: missingRoot,
                log: { _ in },
                progress: { _ in }
            )
            XCTFail("JUnit 配置应被门禁拦住")
        } catch let error as IdeaLightRunError {
            guard case .unsupportedConfiguration = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
        }
    }

    /// §23/§24 约束 8: 遇到 Gradle 项目时不由 GUI / CLI 自己判断——Core 明确报错并点明
    /// Gradle 的支持计划，绝不"跳过构建照常启动"。用真实 Gradle fixture。
    func testGradleProjectFailsClosedWithExplicitReason() async throws {
        let root = Fixtures.url("GradleProject")
        let scan = try IntelliJProjectScanner().scan(projectRoot: root)
        let config = try XCTUnwrap(
            scan.configurations.first { $0.name == "AppApplication" },
            "fixture 里没有 AppApplication 配置"
        )
        do {
            _ = try await ExecutionCoordinator().prepare(
                config: config,
                projectRoot: root,
                log: { _ in },
                progress: { _ in }
            )
            XCTFail("Gradle 项目不该产出一个可启动的计划")
        } catch let error as IdeaLightRunError {
            guard case .buildToolNotFound(let detail) = error else {
                return XCTFail("期望 buildToolNotFound，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("Gradle"), detail)
        }
    }
}
