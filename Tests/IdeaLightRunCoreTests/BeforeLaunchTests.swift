import XCTest
@testable import IdeaLightRunCore

/// §3.2/§3.7: Before Launch 真正执行，且 Core 默认 fail closed。
/// 具体动作由注入的 `Actions` 承担，这里验证"顺序、次数、该拦的拦住"。
final class BeforeLaunchTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private(set) var goalInvocations: [[String]] = []
        private(set) var referencedInvocations: [(name: String, chain: [String])] = []

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }
        func record(_ call: String) {
            lock.lock()
            _calls.append(call)
            lock.unlock()
        }
        func recordGoals(_ goals: [String]) { goalInvocations.append(goals) }
        func recordReferenced(name: String, chain: [String]) {
            referencedInvocations.append((name, chain))
        }
    }

    private func actions(_ recorder: Recorder) -> BeforeLaunchExecutor.Actions {
        BeforeLaunchExecutor.Actions(
            build: { recorder.record("build") },
            buildProject: { recorder.record("buildProject") },
            runMavenGoals: { goals in
                recorder.record("maven")
                recorder.recordGoals(goals)
            },
            runReferenced: { config, chain in
                recorder.record("run:\(config.name)")
                recorder.recordReferenced(name: config.name, chain: chain)
            }
        )
    }

    private func config(
        _ name: String,
        tasks: [BeforeLaunchTask],
        type: RunConfigurationType = .application
    ) -> RunConfiguration {
        RunConfiguration(
            name: name,
            type: type,
            mainClass: "com.example.App",
            beforeLaunchTasks: tasks,
            source: ConfigurationSource(kind: .dotRun, file: URL(fileURLWithPath: "/tmp/\(name).run.xml"), modifiedAt: nil)
        )
    }

    private func silence(_ line: LogLine) {}

    // MARK: - §3.3 Do Not Build

    /// 配置里没有 Make（IDEA 的 "Do not build before run"）时，一个 Build 动作都不能有。
    func testDoNotBuildRunsNoActions() async throws {
        let recorder = Recorder()
        try await BeforeLaunchExecutor().run(
            for: config("NoBuild", tasks: []),
            configurations: [],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.calls, [])
    }

    func testDisabledBuildIsSkipped() async throws {
        let recorder = Recorder()
        try await BeforeLaunchExecutor().run(
            for: config("Disabled", tasks: [BeforeLaunchTask(kind: .build, isEnabled: false)]),
            configurations: [],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.calls, [], "isEnabled=false 的任务不能执行")
    }

    func testEnabledBuildCompilesExactlyOnce() async throws {
        let recorder = Recorder()
        try await BeforeLaunchExecutor().run(
            for: config("Make", tasks: [BeforeLaunchTask(kind: .build, isEnabled: true)]),
            configurations: [],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.calls, ["build"])
    }

    func testBuildProjectIsDistinctFromModuleBuild() async throws {
        let recorder = Recorder()
        try await BeforeLaunchExecutor().run(
            for: config("BP", tasks: [BeforeLaunchTask(kind: .buildProject, isEnabled: true)]),
            configurations: [],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.calls, ["buildProject"])
    }

    /// 任务顺序 = IDEA 里 Before Launch 列表的顺序。
    func testTasksRunInSavedOrder() async throws {
        let recorder = Recorder()
        try await BeforeLaunchExecutor().run(
            for: config("Order", tasks: [
                BeforeLaunchTask(kind: .mavenGoal(goal: "clean"), isEnabled: true),
                BeforeLaunchTask(kind: .build, isEnabled: true),
                BeforeLaunchTask(kind: .buildProject, isEnabled: true),
            ]),
            configurations: [],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.calls, ["maven", "build", "buildProject"])
    }

    // MARK: - §3.5 Maven goal

    func testMavenGoalsArePassedThroughVerbatim() async throws {
        let recorder = Recorder()
        try await BeforeLaunchExecutor().run(
            for: config("MVN", tasks: [
                BeforeLaunchTask(kind: .mavenGoal(goal: "clean package -DskipTests"), isEnabled: true),
            ]),
            configurations: [],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.goalInvocations, [["clean", "package", "-DskipTests"]])
    }

    func testEmptyMavenGoalBlocks() async throws {
        let recorder = Recorder()
        do {
            try await BeforeLaunchExecutor().run(
                for: config("MVN", tasks: [BeforeLaunchTask(kind: .mavenGoal(goal: "  "), isEnabled: true)]),
                configurations: [],
                actions: actions(recorder),
                log: silence
            )
            XCTFail("没有保存 goal 的 Maven.BeforeRunTask 必须拦住")
        } catch let error as IdeaLightRunError {
            guard case .unsupportedBeforeLaunch = error else { return XCTFail("实际：\(error)") }
            XCTAssertEqual(error.title, "Before Launch 任务无法执行")
        }
        XCTAssertEqual(recorder.calls, [])
    }

    // MARK: - §3.2 fail closed

    func testGradleTaskBlocksLaunch() async throws {
        let recorder = Recorder()
        do {
            try await BeforeLaunchExecutor().run(
                for: config("G", tasks: [BeforeLaunchTask(kind: .gradleTask(task: "bootRun"), isEnabled: true)]),
                configurations: [],
                actions: actions(recorder),
                log: silence
            )
            XCTFail("Gradle Before Launch 在 Milestone 4 之前必须拦住")
        } catch let error as IdeaLightRunError {
            guard case .unsupportedBeforeLaunch(let detail) = error else { return XCTFail("实际：\(error)") }
            XCTAssertTrue(detail.contains("bootRun"), "错误里要指出是哪个任务：\(detail)")
        }
    }

    func testUnknownTaskBlocksLaunch() async throws {
        let recorder = Recorder()
        do {
            try await BeforeLaunchExecutor().run(
                for: config("U", tasks: [BeforeLaunchTask(kind: .unknown(raw: "AntBuild"), isEnabled: true)]),
                configurations: [],
                actions: actions(recorder),
                log: silence
            )
            XCTFail("未知任务不能偷偷忽略（§10）")
        } catch let error as IdeaLightRunError {
            guard case .unsupportedBeforeLaunch(let detail) = error else { return XCTFail("实际：\(error)") }
            XCTAssertTrue(detail.contains("AntBuild"))
        }
        XCTAssertEqual(recorder.calls, [])
    }

    /// 用户勾掉复选框的未知任务不再阻塞——它本来就不该执行。
    func testDisabledUnknownTaskDoesNotBlock() async throws {
        let recorder = Recorder()
        try await BeforeLaunchExecutor().run(
            for: config("U", tasks: [BeforeLaunchTask(kind: .unknown(raw: "AntBuild"), isEnabled: false)]),
            configurations: [],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.calls, [])
    }

    func testFailureInFirstTaskStopsTheRest() async throws {
        let recorder = Recorder()
        let executor = BeforeLaunchExecutor()
        let failing = BeforeLaunchExecutor.Actions(
            build: { throw IdeaLightRunError.buildFailed(detail: "编译失败") },
            buildProject: { recorder.record("buildProject") },
            runMavenGoals: { _ in recorder.record("maven") },
            runReferenced: { _, _ in recorder.record("referenced") }
        )
        do {
            try await executor.run(
                for: config("F", tasks: [
                    BeforeLaunchTask(kind: .build, isEnabled: true),
                    BeforeLaunchTask(kind: .buildProject, isEnabled: true),
                ]),
                configurations: [],
                actions: failing,
                log: silence
            )
            XCTFail("编译失败必须向上抛")
        } catch let error as IdeaLightRunError {
            guard case .buildFailed = error else { return XCTFail("实际：\(error)") }
        }
        XCTAssertEqual(recorder.calls, [], "第一个任务失败后不该继续跑后续任务")
    }

    // MARK: - §3.7 Run Another Configuration

    func testReferencedConfigurationRunsFirst() async throws {
        let recorder = Recorder()
        let referenced = config("Pre", tasks: [])
        try await BeforeLaunchExecutor().run(
            for: config("Main", tasks: [
                BeforeLaunchTask(kind: .runConfiguration(name: "Pre", type: "Application"), isEnabled: true),
                BeforeLaunchTask(kind: .build, isEnabled: true),
            ]),
            configurations: [referenced],
            actions: actions(recorder),
            log: silence
        )
        XCTAssertEqual(recorder.calls, ["run:Pre", "build"])
        XCTAssertEqual(recorder.referencedInvocations.first?.chain, ["Main"], "引用链要交给被引用方继续检测环")
    }

    func testMissingReferenceThrows() async throws {
        let recorder = Recorder()
        do {
            try await BeforeLaunchExecutor().run(
                for: config("Main", tasks: [
                    BeforeLaunchTask(kind: .runConfiguration(name: "Ghost", type: nil), isEnabled: true),
                ]),
                configurations: [],
                actions: actions(recorder),
                log: silence
            )
            XCTFail("引用不存在的配置必须报错")
        } catch let error as IdeaLightRunError {
            guard case .referencedConfigurationNotFound = error else { return XCTFail("实际：\(error)") }
            XCTAssertEqual(error.title, "找不到被引用的运行配置")
        }
    }

    func testTypeDisambiguatesSameName() throws {
        let app = config("Same", tasks: [], type: .application)
        let boot = config("Same", tasks: [], type: .springBoot)
        let byType = try BeforeLaunchExecutor.resolveReference(
            name: "Same", type: "SpringBootApplicationConfigurationType", in: [app, boot], from: "X"
        )
        XCTAssertEqual(byType.type, .springBoot)
        let byName = try BeforeLaunchExecutor.resolveReference(name: "Same", type: nil, in: [app, boot], from: "X")
        XCTAssertEqual(byName.type, .application, "没有 type 时按名字兜底取第一个")
    }

    /// §3.7: A → B → A 不能递归跑下去，要报出完整环。
    func testCycleIsReportedWithChain() async throws {
        let recorder = Recorder()
        do {
            try await BeforeLaunchExecutor().run(
                for: config("A", tasks: [
                    BeforeLaunchTask(kind: .runConfiguration(name: "B", type: nil), isEnabled: true),
                ]),
                configurations: [config("B", tasks: [])],
                actions: actions(recorder),
                visiting: ["B"],
                log: silence
            )
            XCTFail("循环引用必须拦住")
        } catch let error as IdeaLightRunError {
            guard case .beforeLaunchCycle(let chain) = error else { return XCTFail("实际：\(error)") }
            XCTAssertEqual(chain, ["B", "A", "B"])
            XCTAssertEqual(error.reason, "Before Launch configuration cycle detected: B -> A -> B")
            XCTAssertEqual(error.title, "Before Launch 循环引用")
        }
        XCTAssertEqual(recorder.calls, [], "发现环之后不能再启动任何进程")
    }

    func testStopBetweenTasksCancels() async throws {
        let recorder = Recorder()
        let handle = ProcessHandle()
        handle.terminate()   // 用户按了 Stop，即使还没有进程在跑
        do {
            try await BeforeLaunchExecutor().run(
                for: config("S", tasks: [BeforeLaunchTask(kind: .build, isEnabled: true)]),
                configurations: [],
                actions: actions(recorder),
                handle: handle,
                log: silence
            )
            XCTFail("已停止的会话不该继续")
        } catch let error as IdeaLightRunError {
            guard case .launchCancelled = error else { return XCTFail("实际：\(error)") }
        }
        XCTAssertEqual(recorder.calls, [])
    }

    // MARK: - §30 XML → 任务

    func testMapperRecognisesBeforeLaunchVariants() throws {
        let parsed = try parseConfiguration("""
        <configuration default="false" name="All" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
          <method v="2">
            <option name="Make" enabled="true" />
            <option name="BuildProject" enabled="true" />
            <option name="Maven.BeforeRunTask" enabled="true" goal="clean package" />
            <option name="Gradle.BeforeRunTask" enabled="true" tasks="assemble" />
            <option name="RunConfigurationTask" enabled="true" run_configuration_name="Pre" run_configuration_type="Application" />
          </method>
        </configuration>
        """)
        XCTAssertEqual(parsed.beforeLaunchTasks, [
            BeforeLaunchTask(kind: .build, isEnabled: true),
            BeforeLaunchTask(kind: .buildProject, isEnabled: true),
            BeforeLaunchTask(kind: .mavenGoal(goal: "clean package"), isEnabled: true),
            BeforeLaunchTask(kind: .gradleTask(task: "assemble"), isEnabled: true),
            BeforeLaunchTask(kind: .runConfiguration(name: "Pre", type: "Application"), isEnabled: true),
        ])
    }

    /// §3.2/§10: 未知任务既要在 GUI 上看得见（warning），也要留在任务列表里让 Core 拦下。
    func testMapperKeepsUnknownTaskForFailClosed() throws {
        let parsed = try parseConfiguration("""
        <configuration default="false" name="U" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
          <method v="2">
            <option name="AntBuild" enabled="true" />
          </method>
        </configuration>
        """)
        XCTAssertEqual(parsed.beforeLaunchTasks, [BeforeLaunchTask(kind: .unknown(raw: "AntBuild"), isEnabled: true)])
        XCTAssertTrue(parsed.warnings.contains(.unsupportedBeforeLaunch(description: "AntBuild")))
    }

    /// 只有 UI 副作用的任务（激活工具窗口）不影响启动，不产生阻塞。
    func testMapperIgnoresToolWindowTask() throws {
        let parsed = try parseConfiguration("""
        <configuration default="false" name="T" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
          <method v="2">
            <option name="ActivateToolWindow" enabled="true" />
            <option name="Make" enabled="true" />
          </method>
        </configuration>
        """)
        XCTAssertEqual(parsed.beforeLaunchTasks, [BeforeLaunchTask(kind: .build, isEnabled: true)])
    }

    /// IDEA 的 "Do not build before run" 写成空的 <method/>：解析结果必须是零任务。
    func testMapperEmptyMethodMeansNoTasks() throws {
        let parsed = try parseConfiguration("""
        <configuration default="false" name="N" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
          <method v="2" />
        </configuration>
        """)
        XCTAssertEqual(parsed.beforeLaunchTasks, [])
    }

    func testMapperRunConfigurationTaskFromWorkspaceChild() throws {
        let parsed = try parseConfiguration("""
        <configuration name="W" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
          <method v="2">
            <option name="RunConfigurationTask">
              <configuration name="Pre" type="SpringBootApplicationConfigurationType" />
            </option>
          </method>
        </configuration>
        """)
        XCTAssertEqual(
            parsed.beforeLaunchTasks,
            [BeforeLaunchTask(kind: .runConfiguration(name: "Pre", type: "SpringBootApplicationConfigurationType"), isEnabled: true)]
        )
    }

    func testMapperMissingReferenceWarns() throws {
        let parsed = try parseConfiguration("""
        <configuration name="M" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
          <method v="2">
            <option name="RunConfigurationTask" enabled="true" />
          </method>
        </configuration>
        """)
        XCTAssertTrue(parsed.warnings.contains(.unsupportedBeforeLaunch(description: "RunConfigurationTask（缺少配置引用）")))
        XCTAssertEqual(parsed.beforeLaunchTasks, [], "没有引用的任务无法执行，只报 warning")
    }

    // MARK: - §4.2 PASS_PARENT_ENVS

    func testMapperReadsPassParentEnvAliases() throws {
        for alias in ["PASS_PARENT_ENVS", "PASS_PARENT_ENV"] {
            let off = try parseConfiguration("""
            <configuration name="P\(alias)" type="Application" factoryName="Application">
              <option name="MAIN_CLASS_NAME" value="com.example.App" />
              <option name="\(alias)" value="false" />
            </configuration>
            """)
            XCTAssertFalse(off.passParentEnvironment, "\(alias)=false 应关闭父进程继承")

            let on = try parseConfiguration("""
            <configuration name="Q\(alias)" type="Application" factoryName="Application">
              <option name="MAIN_CLASS_NAME" value="com.example.App" />
              <option name="\(alias)" value="true" />
            </configuration>
            """)
            XCTAssertTrue(on.passParentEnvironment)
        }
        let absent = try parseConfiguration("""
        <configuration name="Absent" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
        </configuration>
        """)
        XCTAssertTrue(absent.passParentEnvironment, "IDEA 默认继承父进程环境")
    }

    func testMapperReadsEnvFilesAndProvidedScope() throws {
        let parsed = try parseConfiguration("""
        <configuration name="E" type="Application" factoryName="Application">
          <option name="MAIN_CLASS_NAME" value="com.example.App" />
          <option name="ENV_FILES" value="$PROJECT_DIR$/.env:$PROJECT_DIR$/.env.local" />
          <option name="INCLUDE_PROVIDED_SCOPE" value="true" />
        </configuration>
        """)
        XCTAssertEqual(parsed.environmentFiles, ["$PROJECT_DIR$/.env", "$PROJECT_DIR$/.env.local"])
        XCTAssertTrue(parsed.includeProvidedDependencies)
    }

    // MARK: - 辅助

    private func parseConfiguration(_ body: String) throws -> RunConfiguration {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-cfg-\(UUID().uuidString).run.xml")
        try ("<component name=\"ProjectRunConfigurationManager\">\n\(body)\n</component>")
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let configs = try ProjectRunConfigurationParser.parse(fileURL: url, kind: .dotRun)
        return try XCTUnwrap(configs.first)
    }
}
