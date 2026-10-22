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

    /// 临时 Gradle 工程：settings + 假 gradlew（只记录参数，不真的构建）。
    private func makeGradleProject() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lr-gradle-build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        try "rootProject.name = 'demo'\ninclude 'app'\n".write(
            to: root.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8
        )
        try "".write(to: root.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("app/build.gradle"), atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("gradlew")
        try """
        #!/bin/sh
        DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        printf '%s\\n' "$*" >> "$DIR/gradlew.log"
        exit 0
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    /// M4：Gradle 项目不再被拒绝，而是解析出 Gradle 适配器；项目自带 gradlew 优先。
    func testGradleProjectResolvesGradleAdapter() throws {
        try XCTSkipIf(TestToolchain.availableJDK() == nil, "系统没有可用 JDK，跳过工具链测试")
        let root = try makeGradleProject()
        let toolchain = try ProjectToolchain.resolveForProjectBuild(
            projectRoot: root,
            context: "构建",
            log: { _ in }
        )
        XCTAssertEqual(toolchain.kind, .gradle)
        let gradle = try XCTUnwrap(toolchain.adapter as? GradleBuildService)
        XCTAssertEqual(gradle.gradleExecutable.lastPathComponent, "gradlew")
    }

    /// 项目级 Rebuild 走 Gradle 时是 `clean classes`，且 Stop 杀的就是这个进程（--no-daemon）。
    func testGradleProjectBuildRunsCleanThenClasses() async throws {
        try XCTSkipIf(TestToolchain.availableJDK() == nil, "系统没有可用 JDK，跳过工具链测试")
        let root = try makeGradleProject()
        try await ProjectBuilder().build(
            projectRoot: root,
            kind: .rebuild,
            log: { _ in }
        )
        let log = try String(contentsOf: root.appendingPathComponent("gradlew.log"), encoding: .utf8)
        XCTAssertEqual(log.trimmingCharacters(in: .whitespacesAndNewlines), "--console=plain --no-daemon clean classes")
    }

    func testErrorMessageReflectsCallingContext() throws {
        // 同一段解析被启动与三种构建动作复用，报错里的动作名必须跟着调用方走
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-no-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: emptyRoot) }
        func detail(_ context: String) -> String {
            do {
                _ = try ProjectToolchain.resolveForProjectBuild(
                    projectRoot: emptyRoot,
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
        XCTAssertTrue(detail("启动").contains("无法启动该项目"))
        XCTAssertTrue(detail("构建").contains("无法构建该项目"))
        XCTAssertTrue(detail("清理").contains("无法清理该项目"))
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
