import XCTest
@testable import IdeaLightRunCore

/// IDEA 的 Build / Rebuild Project 与 Maven clean：项目级、作用于整个 reactor。
/// 回归——项目级构建不能带 `-pl/-am`（那会把范围缩到单个模块），
/// Rebuild 必须带 `clean`（IDEA 的 Rebuild 先清空产物再全量编译），
/// Clean 只有 `clean`（清空产物后不能顺手编译，否则和 Rebuild 没有区别）。
final class ProjectBuildTests: XCTestCase {
    private func arguments(
        _ kind: ProjectBuildKind,
        executableName: String = "mvn",
        noSnapshotUpdates: Bool = true
    ) -> [String] {
        MavenBuildService.projectBuildArguments(
            mavenExecutable: URL(fileURLWithPath: "/usr/local/bin/\(executableName)"),
            noSnapshotUpdates: noSnapshotUpdates,
            kind: kind
        )
    }

    func testBuildIsIncrementalCompile() {
        XCTAssertEqual(arguments(.build), ["-B", "-nsu", "-DskipTests", "compile"])
    }

    func testRebuildCleansBeforeCompiling() {
        XCTAssertEqual(arguments(.rebuild), ["-B", "-nsu", "-DskipTests", "clean", "compile"])
    }

    func testCleanOnlyRemovesArtifacts() {
        XCTAssertEqual(arguments(.clean), ["-B", "-nsu", "clean"])
    }

    func testProjectBuildHasNoModuleFilter() {
        for kind in ProjectBuildKind.allCases {
            let arguments = self.arguments(kind)
            XCTAssertFalse(arguments.contains("-pl"), "\(kind) 不应带 -pl")
            XCTAssertFalse(arguments.contains("-am"), "\(kind) 不应带 -am")
        }
    }

    func testWrapperOmitsBatchFlag() {
        XCTAssertEqual(
            arguments(.build, executableName: "mvnw"),
            ["-nsu", "-DskipTests", "compile"]
        )
    }

    func testSnapshotCheckCanBeForced() {
        XCTAssertEqual(
            arguments(.rebuild, noSnapshotUpdates: false),
            ["-B", "-DskipTests", "clean", "compile"]
        )
    }

    // MARK: - 动作名与文案

    /// 日志里的 goal 序列必须与实际传给 Maven 的一致，否则用户按输出复现不了。
    func testGoalsDescriptionMatchesWhatIsPassedToMaven() {
        for kind in ProjectBuildKind.allCases {
            let goals = arguments(kind).filter { !$0.hasPrefix("-") && $0 != "mvn" }
            XCTAssertEqual(kind.goalsDescription, goals.joined(separator: " "), "\(kind)")
        }
    }

    func testActionNameCoversAllThreeActions() {
        XCTAssertEqual(
            ProjectBuildKind.allCases.map(\.actionName),
            ["构建", "重新构建", "清理"]
        )
    }

    // MARK: - 工具链解析（§4：与启动共用一套）

    func testGradleProjectIsRejectedForBuild() {
        do {
            _ = try ProjectToolchain.resolveMaven(
                projectRoot: Fixtures.url("GradleProject"),
                context: ProjectBuildKind.build.actionName,
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
        // 同一段解析被启动与三种构建动作复用，报错里的动作名必须跟着调用方走
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
        XCTAssertTrue(detail("清理").contains("直接清理"))
    }

    /// "停止"按在 Maven 起来之前：没有进程可终止，只能靠取消标记，
    /// 并且必须报成"已停止"而不是"构建失败"。
    func testCancelBeforeMavenStartsIsReportedAsCancelled() async {
        let handle = ProcessHandle()
        handle.terminate()
        do {
            try await ProjectBuilder().build(
                projectRoot: Fixtures.url("MavenMultiProject"),
                kind: .build,
                log: { _ in },
                processHandle: handle
            )
            XCTFail("已停止的构建不应继续执行")
        } catch let error as IdeaLightRunError {
            guard case .launchCancelled(let detail) = error else {
                return XCTFail("期望 launchCancelled，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("构建"), detail)
        } catch {
            XCTFail("期望 launchCancelled，实际 \(error)")
        }
    }

    /// 清理同样受停止保护：取消文案要说是"清理"被停止，而不是"构建"。
    func testCancelDuringCleanReportsCleanContext() async {
        let handle = ProcessHandle()
        handle.terminate()
        do {
            try await ProjectBuilder().build(
                projectRoot: Fixtures.url("MavenMultiProject"),
                kind: .clean,
                log: { _ in },
                processHandle: handle
            )
            XCTFail("已停止的清理不应继续执行")
        } catch let error as IdeaLightRunError {
            guard case .launchCancelled(let detail) = error else {
                return XCTFail("期望 launchCancelled，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("清理"), detail)
        } catch {
            XCTFail("期望 launchCancelled，实际 \(error)")
        }
    }
}
