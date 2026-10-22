import XCTest
@testable import IdeaLightRunCore

/// M4: Gradle 适配器。用假 `gradlew` 记录参数并写 classpath 文件，
/// 真实 Gradle 行为不在单测里跑——这里钉住参数形状、project path 与缓存语义。
final class GradleBuildServiceTests: XCTestCase {
    private final class StubProject {
        let root: URL
        let fm = FileManager.default

        var gradlew: URL { root.appendingPathComponent("gradlew") }
        var settingsURL: URL { root.appendingPathComponent("settings.gradle") }
        var gradleUserHome: URL { root.appendingPathComponent(".gradle-home", isDirectory: true) }
        var appClasses: URL { root.appendingPathComponent("app/build/classes/java/main", isDirectory: true) }
        var stubJar: URL { root.appendingPathComponent("lib/stub.jar") }
        var logURL: URL { root.appendingPathComponent("gradlew.log") }
        var logText: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
        var invocations: [[String]] {
            logText.split(whereSeparator: \.isNewline)
                .map { $0.split(separator: " ").map(String.init) }
        }

        init(settings: String? = "rootProject.name = 'demo'\ninclude 'app'\ninclude 'library:util'\n") throws {
            root = fm.temporaryDirectory
                .appendingPathComponent("lr-gradle-stub-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            for directory in ["app", "library/util", "lib", ".gradle-home"] {
                try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            if let settings {
                try settings.write(to: settingsURL, atomically: true, encoding: .utf8)
            }
            for path in ["build.gradle", "app/build.gradle", "library/util/build.gradle"] {
                try "".write(
                    to: root.appendingPathComponent(path), atomically: true, encoding: .utf8
                )
            }
            try fm.createDirectory(at: appClasses, withIntermediateDirectories: true)
            try Data("PK".utf8).write(to: stubJar)
            try installStub()
        }

        /// classpathMode: normal 写出两条真实条目；empty 写空文件；none 不写文件。
        func installStub(exitCode: Int = 0, classpathMode: String = "normal") throws {
            let body: String
            switch classpathMode {
            case "empty":
                body = "            : > \"$out\""
            case "none":
                body = "            :"
            default:
                body = """
                            mkdir -p "$(dirname "$out")"
                            printf '%s\\n%s\\n' "$DIR/app/build/classes/java/main" "$DIR/lib/stub.jar" > "$out"
                """
            }
            try """
            #!/bin/sh
            DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
            printf '%s\\n' "$*" >> "$DIR/gradlew.log"
            echo "BUILD SUCCESSFUL"
            out=""
            for arg in "$@"; do
                case "$arg" in
                    -Didealightrun.classpath.file=*) out="${arg#-Didealightrun.classpath.file=}" ;;
                esac
            done
            if [ -n "$out" ]; then
                mkdir -p "$(dirname "$out")"
            \(body)
            fi
            exit \(exitCode)
            """.write(to: gradlew, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gradlew.path)
        }

        func service(modules: [ProjectModule] = []) -> GradleBuildService {
            GradleBuildService(
                projectRoot: root,
                settingsURL: settingsURL,
                modules: modules,
                gradleExecutable: gradlew,
                environment: ["PATH": "/usr/bin:/bin"],
                jdkMajorVersion: 17,
                gradleUserHome: gradleUserHome
            )
        }

        func appModule() -> ProjectModule {
            ProjectModule(name: "app", directory: root.appendingPathComponent("app"), gradlePath: ":app")
        }

        func delete() {
            for module in [":app", ":library:util", ":"] {
                ClasspathCache.clear(projectRoot: root, moduleName: module, buildSystem: "gradle")
            }
            try? fm.removeItem(at: root)
        }
    }

    private var project: StubProject!

    override func setUpWithError() throws {
        project = try StubProject()
    }

    override func tearDown() {
        project.delete()
        project = nil
    }

    // MARK: - 项目索引

    func testProjectIndexReadsSettingsAndProjectDirMapping() throws {
        let settings = """
        rootProject.name = 'demo'
        include 'app'
        include 'library:util'
        project(':library:util').projectDir = file('modules/util')
        """
        try settings.write(to: project.settingsURL, atomically: true, encoding: .utf8)

        let projects = project.service().projects
        XCTAssertEqual(projects.map(\.path), [":", ":app", ":library:util"])
        XCTAssertEqual(projects.map(\.name), ["demo", "app", "util"])
        func path(_ url: URL) -> String {
            var value = url.standardizedFileURL.path
            if value.count > 1, value.hasSuffix("/") { value.removeLast() }
            return value
        }
        XCTAssertEqual(
            path(projects[1].directory),
            path(project.root.appendingPathComponent("app"))
        )
        XCTAssertEqual(
            path(projects[2].directory),
            path(project.root.appendingPathComponent("modules/util")),
            "显式的 projectDir 映射优先于按 path 拼接"
        )
    }

    func testProjectIndexWithoutSettingsKeepsRootAndIMLModules() {
        let modules = [ProjectModule(
            name: "custom",
            directory: project.root.appendingPathComponent("custom"),
            gradlePath: ":custom"
        )]
        let service = GradleBuildService(
            projectRoot: project.root,
            settingsURL: nil,
            modules: modules,
            gradleExecutable: project.gradlew,
            environment: [:],
            gradleUserHome: project.gradleUserHome
        )
        XCTAssertEqual(service.projects.map(\.path), [":", ":custom"])
        XCTAssertEqual(service.projects.first?.name, project.root.lastPathComponent)
    }

    func testGradlePathResolutionUsesPathDirectoryThenName() {
        let service = project.service()
        let rootModule = ProjectModule(name: "demo", directory: project.root)
        XCTAssertEqual(service.gradlePath(for: rootModule), ":")

        let app = project.appModule()
        XCTAssertEqual(service.gradlePath(for: app), ":app")

        let byDirectory = ProjectModule(
            name: "renamed",
            directory: project.root.appendingPathComponent("library/util")
        )
        XCTAssertEqual(service.gradlePath(for: byDirectory), ":library:util")

        let byName = ProjectModule(name: "util", directory: project.root.appendingPathComponent("elsewhere"))
        XCTAssertEqual(service.gradlePath(for: byName), ":library:util")

        let unknown = ProjectModule(name: "ghost", directory: project.root.appendingPathComponent("ghost"))
        XCTAssertEqual(service.gradlePath(for: unknown), ":ghost", "映射不出来时交给 Gradle 报错，不能悄悄回退到根项目")
    }

    func testClasspathVariantUsesGradleProjectPath() {
        let service = project.service()
        let variant = service.classpathVariant(for: project.appModule(), includeProvided: false)
        XCTAssertEqual(variant, .gradle(module: ":app", includeProvided: false))
    }

    // MARK: - 参数

    func testCommandArgumentsHaveStableOrder() {
        XCTAssertEqual(
            GradleBuildService.commandArguments(
                tasks: ["clean"],
                systemProperties: ["b": "2", "a": "1"],
                initScript: URL(fileURLWithPath: "/tmp/init.gradle")
            ),
            [
                "-Da=1", "-Db=2",
                "--console=plain", "--no-daemon",
                "--init-script", "/tmp/init.gradle",
                "clean",
            ]
        )
    }

    func testProjectTasksMatchIDEA() {
        XCTAssertEqual(GradleBuildService.projectTasks(for: .build), ["classes"])
        XCTAssertEqual(GradleBuildService.projectTasks(for: .rebuild), ["clean", "classes"])
        XCTAssertEqual(GradleBuildService.projectTasks(for: .clean), ["clean"])
    }

    func testTaskPathForRootAndSubprojects() {
        XCTAssertEqual(GradleBuildService.taskPath(":", "classes"), ":classes")
        XCTAssertEqual(GradleBuildService.taskPath(":app", "classes"), ":app:classes")
        XCTAssertEqual(GradleBuildService.taskPath(":library:util", "classes"), ":library:util:classes")
    }

    func testSplitClasspathDeduplicatesAndDropsEmptyLines() {
        XCTAssertEqual(
            GradleBuildService.splitClasspath("/a.jar\n\n /b.jar \n/a.jar\n"),
            ["/a.jar", "/b.jar"]
        )
    }

    // MARK: - 构建

    func testBuildModuleUsesProjectPathTask() throws {
        var lines: [String] = []
        try project.service().buildModule(
            BuildTarget(module: project.appModule(), variant: .gradle(module: ":app", includeProvided: false)),
            handle: nil,
            log: { lines.append($0.text) }
        )
        XCTAssertEqual(project.invocations, [["--console=plain", "--no-daemon", ":app:classes"]])
        XCTAssertTrue(lines.contains("BUILD SUCCESSFUL"), "构建输出要逐行回传：\(lines)")
    }

    func testProjectRebuildRunsCleanThenClasses() throws {
        try project.service().buildProject(kind: .rebuild, handle: nil, log: { _ in })
        XCTAssertEqual(project.invocations, [["--console=plain", "--no-daemon", "clean", "classes"]])
    }

    func testBuildFailureReportsExitCode() {
        do {
            try project.installStub(exitCode: 3)
            try project.service().buildModule(
                BuildTarget(module: project.appModule(), variant: .gradle(module: ":app", includeProvided: false)),
                handle: nil,
                log: { _ in }
            )
            XCTFail("失败退出码不能被吞掉")
        } catch let error as IdeaLightRunError {
            guard case .buildFailed(let detail) = error else { return XCTFail("实际：\(error)") }
            XCTAssertTrue(detail.contains("退出码 3"), detail)
        } catch {
            XCTFail("实际：\(error)")
        }
    }

    func testStopBeforeProcessStartsIsReportedAsCancelled() {
        let handle = ProcessHandle()
        handle.terminate()
        do {
            try project.service().buildModule(
                BuildTarget(module: project.appModule(), variant: .gradle(module: ":app", includeProvided: false)),
                handle: handle,
                log: { _ in }
            )
            XCTFail("已取消的构建不能继续执行")
        } catch let error as IdeaLightRunError {
            guard case .launchCancelled = error else { return XCTFail("实际：\(error)") }
        } catch {
            XCTFail("实际：\(error)")
        }
    }

    // MARK: - classpath

    private func target(includeProvided: Bool = false) -> BuildTarget {
        BuildTarget(
            module: project.appModule(),
            variant: .gradle(module: ":app", includeProvided: includeProvided)
        )
    }

    func testRuntimeClasspathMergesCompileAndResolveIntoOneCall() throws {
        let entries = try project.service().runtimeClasspath(
            target(), withBuild: true, handle: nil, log: { _ in }
        )
        XCTAssertEqual(entries, [project.appClasses.path, project.stubJar.path])
        XCTAssertEqual(project.invocations.count, 1, "冷启动只启动一次 Gradle：\(project.logText)")
        let arguments = try XCTUnwrap(project.invocations.first)
        XCTAssertTrue(arguments.contains(":app:classes"), "\(arguments)")
        XCTAssertTrue(arguments.contains(":app:ideaLightRunClasspath"), "\(arguments)")
        XCTAssertTrue(arguments.contains("--init-script"), "\(arguments)")
        XCTAssertTrue(arguments.contains("-Didealightrun.include.provided=false"), "\(arguments)")

        XCTAssertTrue(project.service().hasFreshClasspathCache(for: target()))
        let cached = ClasspathCache.load(
            projectRoot: project.root,
            variant: .gradle(module: ":app", includeProvided: false)
        )
        XCTAssertEqual(cached?.entries, entries)
    }

    /// Do not build before run：withBuild=false 时只能解析，不能编译。
    func testRuntimeClasspathWithoutBuildNeverCompiles() throws {
        let entries = try project.service().runtimeClasspath(
            target(), withBuild: false, handle: nil, log: { _ in }
        )
        XCTAssertEqual(entries.count, 2)
        let arguments = try XCTUnwrap(project.invocations.first)
        XCTAssertFalse(arguments.contains(":app:classes"), "\(arguments)")
        XCTAssertTrue(arguments.contains(":app:ideaLightRunClasspath"), "\(arguments)")
        XCTAssertEqual(project.invocations.count, 1)
    }

    func testWarmCacheSkipsResolutionButStillBuildsWhenAsked() throws {
        let service = project.service()
        _ = try service.runtimeClasspath(target(), withBuild: true, handle: nil, log: { _ in })
        XCTAssertEqual(project.invocations.count, 1)

        _ = try service.runtimeClasspath(target(), withBuild: false, handle: nil, log: { _ in })
        XCTAssertEqual(project.invocations.count, 1, "缓存命中时不需要再调用 Gradle")

        _ = try service.runtimeClasspath(target(), withBuild: true, handle: nil, log: { _ in })
        XCTAssertEqual(project.invocations.count, 2, "缓存命中但要求构建时只编译：\n\(project.logText)")
        let warmBuild = try XCTUnwrap(project.invocations.last)
        XCTAssertTrue(warmBuild.contains(":app:classes"))
        XCTAssertFalse(warmBuild.contains(":app:ideaLightRunClasspath"))
    }

    /// includeProvided 是独立的缓存身份，并且要传给 init script。
    func testProvidedClasspathHasItsOwnVariantAndFlag() throws {
        let service = project.service()
        let entries = try service.runtimeClasspath(
            target(includeProvided: true), withBuild: false, handle: nil, log: { _ in }
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(project.logText.contains("-Didealightrun.include.provided=true"), project.logText)
        XCTAssertNotNil(
            ClasspathCache.load(projectRoot: project.root, variant: .gradle(module: ":app", includeProvided: true))
        )
        XCTAssertNil(
            ClasspathCache.load(projectRoot: project.root, variant: .gradle(module: ":app", includeProvided: false)),
            "两种变体不能共用缓存"
        )
    }

    func testMissingClasspathFileFailsWithPath() {
        do {
            try project.installStub(classpathMode: "none")
            _ = try project.service().runtimeClasspath(target(), withBuild: false, handle: nil, log: { _ in })
            XCTFail("没有输出文件时必须报错")
        } catch let error as IdeaLightRunError {
            guard case .classpathResolveFailed(let detail) = error else { return XCTFail("实际：\(error)") }
            XCTAssertTrue(detail.contains("未生成 classpath 输出文件"), detail)
        } catch {
            XCTFail("实际：\(error)")
        }
    }

    /// 没有 main source set（例如只有 Kotlin 插件之外的 settings-only 子项目）时，
    /// 空输出必须报成可理解的错误，而不是让 Java 用空 -cp 启动。
    func testEmptyClasspathFailsWithSourceSetHint() {
        do {
            try project.installStub(classpathMode: "empty")
            _ = try project.service().runtimeClasspath(target(), withBuild: false, handle: nil, log: { _ in })
            XCTFail("空 classpath 不能当作成功")
        } catch let error as IdeaLightRunError {
            guard case .classpathResolveFailed(let detail) = error else { return XCTFail("实际：\(error)") }
            XCTAssertTrue(detail.contains("main source set"), detail)
        } catch {
            XCTFail("实际：\(error)")
        }
    }

    /// 构建脚本变化必须让缓存失效（否则新依赖永远不会出现在 classpath 里）。
    func testBuildScriptChangeInvalidatesFingerprint() throws {
        let service = project.service()
        _ = try service.runtimeClasspath(target(), withBuild: false, handle: nil, log: { _ in })
        XCTAssertTrue(service.hasFreshClasspathCache(for: target()))

        try "dependencies { implementation 'x:y:1.0' }\n".write(
            to: project.root.appendingPathComponent("app/build.gradle"), atomically: true, encoding: .utf8
        )
        XCTAssertFalse(service.hasFreshClasspathCache(for: target()))
    }
}
