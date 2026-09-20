import XCTest
@testable import IdeaLightRunCore

/// IDEA 的 Build Project / Rebuild Project：项目级、作用于整个 reactor。
/// 回归——项目级构建不能带 `-pl/-am`（那会把范围缩到单个模块），
/// Rebuild 必须带 `clean`（IDEA 的 Rebuild 先清空产物再全量编译）。
final class ProjectBuildTests: XCTestCase {
    private func arguments(
        rebuild: Bool,
        executableName: String = "mvn",
        noSnapshotUpdates: Bool = true
    ) -> [String] {
        MavenBuildService.projectBuildArguments(
            mavenExecutable: URL(fileURLWithPath: "/usr/local/bin/\(executableName)"),
            noSnapshotUpdates: noSnapshotUpdates,
            rebuild: rebuild
        )
    }

    func testBuildIsIncrementalCompile() {
        XCTAssertEqual(arguments(rebuild: false), ["-B", "-nsu", "-DskipTests", "compile"])
    }

    func testRebuildCleansBeforeCompiling() {
        XCTAssertEqual(arguments(rebuild: true), ["-B", "-nsu", "-DskipTests", "clean", "compile"])
    }

    func testProjectBuildHasNoModuleFilter() {
        let arguments = arguments(rebuild: true)
        XCTAssertFalse(arguments.contains("-pl"))
        XCTAssertFalse(arguments.contains("-am"))
    }

    func testWrapperOmitsBatchFlag() {
        XCTAssertEqual(
            arguments(rebuild: false, executableName: "mvnw"),
            ["-nsu", "-DskipTests", "compile"]
        )
    }

    func testSnapshotCheckCanBeForced() {
        XCTAssertEqual(
            arguments(rebuild: true, noSnapshotUpdates: false),
            ["-B", "-DskipTests", "clean", "compile"]
        )
    }

    // MARK: - 工具链解析（§4：与启动共用一套）

    func testGradleProjectIsRejectedForBuild() {
        do {
            _ = try ProjectToolchain.resolveMaven(
                projectRoot: Fixtures.url("GradleProject"),
                context: "构建",
                log: { _ in }
            )
            XCTFail("Gradle 项目当前不应进入构建流程")
        } catch let error as IdeaLightRunError {
            guard case .buildToolNotFound(let detail) = error else {
                return XCTFail("期望 buildToolNotFound，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("仅支持 Maven 项目直接构建"), detail)
        } catch {
            XCTFail("期望 buildToolNotFound，实际 \(error)")
        }
    }

    func testErrorMessageReflectsCallingContext() {
        // 同一段解析被启动与构建复用，报错里的动作名必须跟着调用方走
        let gradleRoot = Fixtures.url("GradleProject")
        func detail(_ context: String) -> String {
            do {
                _ = try ProjectToolchain.resolveMaven(
                    projectRoot: gradleRoot,
                    context: context,
                    log: { _ in }
                )
                return ""
            } catch let error as IdeaLightRunError {
                return error.reason
            } catch {
                return "\(error)"
            }
        }
        XCTAssertTrue(detail("启动").contains("直接启动"))
        XCTAssertTrue(detail("构建").contains("直接构建"))
    }

    /// "停止"按在 Maven 起来之前：没有进程可终止，只能靠取消标记，
    /// 并且必须报成"已停止"而不是"构建失败"。
    func testCancelBeforeMavenStartsIsReportedAsCancelled() async {
        let handle = ProcessHandle()
        handle.terminate()
        do {
            try await ProjectBuilder().build(
                projectRoot: Fixtures.url("MavenMultiProject"),
                rebuild: false,
                log: { _ in },
                processHandle: handle
            )
            XCTFail("已停止的构建不应继续执行")
        } catch let error as IdeaLightRunError {
            guard case .launchCancelled = error else {
                return XCTFail("期望 launchCancelled，实际 \(error)")
            }
        } catch {
            XCTFail("期望 launchCancelled，实际 \(error)")
        }
    }
}
