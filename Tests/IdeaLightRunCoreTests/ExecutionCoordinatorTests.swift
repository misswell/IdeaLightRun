import XCTest
@testable import IdeaLightRunCore

/// §8/§22/§23: `ExecutionCoordinator` 是 GUI 与 CLI 唯一的启动入口，
/// 「这个配置能不能跑」也只在这里判断。界面侧不许复制一份 `if SpringBoot`，
/// 所以门禁必须排在扫盘、定位 Maven、解析 JDK 之前，并且与
/// `ConfigurationCapabilityResolver` 同源。
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

    func testApplicationSpringBootAndJarPassTheGate() throws {
        XCTAssertNoThrow(try ExecutionCoordinator.ensureRunnable(config(.application)))
        XCTAssertNoThrow(try ExecutionCoordinator.ensureRunnable(config(.springBoot)))
        let jar = RunConfiguration(
            name: "StandaloneJar",
            type: .jar,
            jarPath: "/tmp/app.jar",
            source: ConfigurationSource(
                kind: .dotRun,
                file: URL(fileURLWithPath: "/tmp/StandaloneJar.run.xml"),
                modifiedAt: nil
            )
        )
        XCTAssertNoThrow(try ExecutionCoordinator.ensureRunnable(jar))
    }

    /// 其余类型一律明确拒绝，且说清是哪个配置的哪种类型（§24 约束 8：不许静默跳过）。
    func testOtherTypesAreRejectedWithReason() {
        let rejected: [(RunConfigurationType, String)] = [
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

    /// 门禁与界面徽标同源：Core 计算出的 `isLaunchable` 与放行的集合一致，
    /// 不会出现「行内说 Ready、点了被拦」或反之。
    func testGateAgreesWithCapabilityBadge() {
        let all: [RunConfigurationType] = [
            .application, .springBoot, .jar, .maven, .gradle, .compound, .junit, .unknown("X"),
        ]
        for type in all {
            let passes = (try? ExecutionCoordinator.ensureRunnable(config(type))) != nil
            let capability = ConfigurationCapabilityResolver.resolve(config(type))
            XCTAssertEqual(passes, capability.isLaunchable, "\(type)")
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

    // MARK: - Compound 准备

    private func makeProject() throws -> (root: URL, jdk: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lr-compound-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent(".run"), withIntermediateDirectories: true)
        let jdk = fm.temporaryDirectory
            .appendingPathComponent("lr-compound-jdk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: jdk.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let java = jdk.appendingPathComponent("bin/java")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: java)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        addTeardownBlock {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: jdk)
        }
        return (root, jdk)
    }

    @discardableResult
    private func writeJar(_ name: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent("\(name).jar")
        try Data("PK".utf8).write(to: url)
        return url
    }

    private func writeJarConfig(_ name: String, jar: URL, jdk: URL, root: URL) throws {
        let xml = """
        <component name="ProjectRunConfigurationManager">
          <configuration default="false" name="\(name)" type="JarApplicationType" factoryName="Jar Application">
            <option name="JAR_PATH" value="\(jar.path)" />
            <option name="ALTERNATIVE_JRE_PATH" value="\(jdk.path)" />
            <option name="ALTERNATIVE_JRE_PATH_ENABLED" value="true" />
          </configuration>
        </component>
        """
        try Data(xml.utf8).write(to: root.appendingPathComponent(".run/\(name).run.xml"))
    }

    private func writeCompoundConfig(
        _ name: String,
        members: [(name: String, type: String)],
        root: URL
    ) throws {
        let references = members
            .map { #"  <toRun name="\#($0.name)" type="\#($0.type)" />"# }
            .joined(separator: "\n")
        let xml = """
        <component name="ProjectRunConfigurationManager">
          <configuration default="false" name="\(name)" type="CompoundRunConfigurationType" factoryName="Compound">
        \(references)
          </configuration>
        </component>
        """
        try Data(xml.utf8).write(to: root.appendingPathComponent(".run/\(name).run.xml"))
    }

    private func compound(named name: String, in root: URL) async throws
        -> (configuration: RunConfiguration, execution: PreparedExecution) {
        let scan = try IntelliJProjectScanner().scan(projectRoot: root)
        let config = try XCTUnwrap(scan.configurations.first { $0.name == name })
        let execution = try await ExecutionCoordinator().prepare(
            config: config,
            projectRoot: root,
            log: { _ in },
            progress: { _ in }
        )
        return (config, execution)
    }

    /// 成员按 IDEA 里保存的顺序准备，全部成功后一次性交出多进程计划；
    /// 每个成员仍是完整的 JAR 启动计划（走同一条 Planner）。
    func testCompoundPreparesJarMembersInReferenceOrder() async throws {
        let (root, jdk) = try makeProject()
        let one = try writeJar("one", root: root)
        let two = try writeJar("two", root: root)
        try writeJarConfig("One", jar: one, jdk: jdk, root: root)
        try writeJarConfig("Two", jar: two, jdk: jdk, root: root)
        try writeCompoundConfig("All", members: [
            ("Two", "JarApplicationType"),
            ("One", "JarApplicationType"),
        ], root: root)

        let scan = try IntelliJProjectScanner().scan(projectRoot: root)
        let all = try XCTUnwrap(scan.configurations.first { $0.name == "All" })
        XCTAssertEqual(
            ConfigurationCapabilityResolver.resolve(all, scan: scan).readiness,
            .ready,
            "两个 JAR 成员都可启动时 Compound 不应被标成 planned"
        )

        let execution = try await compound(named: "All", in: root)
        guard case .compound(let plan) = execution.execution else {
            return XCTFail("Compound 应产出多进程计划")
        }
        XCTAssertEqual(plan.members.map(\.name), ["Two", "One"])
        XCTAssertEqual(plan.members.map(\.configurationKey), [
            "JarApplicationType::Two",
            "JarApplicationType::One",
        ])
        XCTAssertEqual(plan.members[0].execution.processPlan?.arguments.last, two.path)
        XCTAssertEqual(plan.members[1].execution.processPlan?.arguments.last, one.path)
    }

    /// 嵌套 Compound 在准备阶段展开成叶子成员：运行时只面对真实进程，
    /// 分组停止/日志归属也因此不会多出一层没有进程的“成员”。
    func testNestedCompoundFlattensLeafMembers() async throws {
        let (root, jdk) = try makeProject()
        let leaf = try writeJar("leaf", root: root)
        try writeJarConfig("Leaf", jar: leaf, jdk: jdk, root: root)
        try writeCompoundConfig("Inner", members: [("Leaf", "JarApplicationType")], root: root)
        try writeCompoundConfig("Outer", members: [("Inner", "CompoundRunConfigurationType")], root: root)

        let execution = try await compound(named: "Outer", in: root)
        guard case .compound(let plan) = execution.execution else {
            return XCTFail("Outer 应产出多进程计划")
        }
        XCTAssertEqual(plan.name, "Outer")
        XCTAssertEqual(plan.members.map(\.name), ["Leaf"])
    }

    /// 缺失成员在准备阶段就失败，不会先启动任何成员进程。
    func testCompoundMissingMemberFailsBeforeAnyLaunch() async throws {
        let (root, jdk) = try makeProject()
        let one = try writeJar("one", root: root)
        try writeJarConfig("One", jar: one, jdk: jdk, root: root)
        try writeCompoundConfig("All", members: [
            ("One", "JarApplicationType"),
            ("Ghost", "JarApplicationType"),
        ], root: root)

        do {
            _ = try await compound(named: "All", in: root)
            XCTFail("引用缺失成员的 Compound 不应准备成功")
        } catch let error as IdeaLightRunError {
            guard case .unsupportedConfiguration(let detail) = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("Ghost"), detail)
        }
    }

    /// 成环的 Compound 在准备阶段失败，而不是递归到栈溢出。
    func testCompoundCycleIsRejected() async throws {
        let (root, jdk) = try makeProject()
        let one = try writeJar("one", root: root)
        try writeJarConfig("One", jar: one, jdk: jdk, root: root)
        try writeCompoundConfig("A", members: [("B", "CompoundRunConfigurationType")], root: root)
        try writeCompoundConfig("B", members: [("A", "CompoundRunConfigurationType")], root: root)

        do {
            _ = try await compound(named: "A", in: root)
            XCTFail("成环的 Compound 不应准备成功")
        } catch let error as IdeaLightRunError {
            guard case .unsupportedConfiguration(let detail) = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("循环"), detail)
        }
    }

    /// M4: Gradle 项目走同一条启动流水线。假 gradlew 只记录参数并写出 classpath，
    /// 用真实 fixture 的 settings.gradle / module 结构验证 project path 与合并调用。
    func testGradleApplicationPreparesPlanWithGradleClasspath() async throws {
        try XCTSkipIf(TestToolchain.availableJDK() == nil, "系统没有可用 JDK，跳过 Gradle 启动流水线测试")
        let jdk = try XCTUnwrap(TestToolchain.availableJDK())
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lr-gradle-run-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: Fixtures.url("GradleProject"), to: root)
        addTeardownBlock {
            ClasspathCache.clear(projectRoot: root, variant: .gradle(module: ":app", includeProvided: false))
            ClasspathCache.clear(projectRoot: root, variant: .gradle(module: ":app", includeProvided: true))
            try? FileManager.default.removeItem(at: root)
        }

        let appClasses = root.appendingPathComponent("app/build/classes/java/main", isDirectory: true)
        let utilClasses = root.appendingPathComponent("library/util/build/classes/java/main", isDirectory: true)
        try fm.createDirectory(at: appClasses, withIntermediateDirectories: true)
        try fm.createDirectory(at: utilClasses, withIntermediateDirectories: true)
        let stubJar = root.appendingPathComponent("lib/stub.jar")
        try fm.createDirectory(at: stubJar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PK".utf8).write(to: stubJar)

        let wrapper = root.appendingPathComponent("gradlew")
        try """
        #!/bin/sh
        DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        printf '%s\\n' "$*" >> "$DIR/gradlew.log"
        out=""
        for arg in "$@"; do
            case "$arg" in
                -Didealightrun.classpath.file=*) out="${arg#-Didealightrun.classpath.file=}" ;;
            esac
        done
        if [ -n "$out" ]; then
            mkdir -p "$(dirname "$out")"
            printf '%s\\n%s\\n' "$DIR/app/build/classes/java/main" "$DIR/lib/stub.jar" > "$out"
        fi
        exit 0
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        // fixture 的 project SDK 是 "17"；这里显式指定本机可用 JDK，避免机器没装 17 时误跳。
        try """
        <component name="ProjectRunConfigurationManager">
          <configuration default="false" name="AppApplication" type="SpringBootApplicationConfigurationType" factoryName="Spring Boot">
            <module name="app" />
            <option name="SPRING_BOOT_MAIN_CLASS" value="com.example.app.AppApplication" />
            <option name="ALTERNATIVE_JRE_PATH" value="\(jdk.home.path)" />
            <option name="ALTERNATIVE_JRE_PATH_ENABLED" value="true" />
            <method v="2">
              <option name="Make" enabled="true" />
            </method>
          </configuration>
        </component>
        """.write(to: root.appendingPathComponent(".run/AppApplication.run.xml"), atomically: true, encoding: .utf8)

        let scan = try IntelliJProjectScanner().scan(projectRoot: root)
        let config = try XCTUnwrap(scan.configurations.first { $0.name == "AppApplication" })
        XCTAssertEqual(
            ConfigurationCapabilityResolver.resolve(config, scan: scan).readiness,
            .ready,
            "Gradle Spring Boot 配置应可启动"
        )

        let execution = try await ExecutionCoordinator().prepare(
            config: config,
            projectRoot: root,
            log: { _ in },
            progress: { _ in }
        )
        let plan = try XCTUnwrap(execution.processPlan)
        XCTAssertEqual(plan.mainClass, "com.example.app.AppApplication")
        XCTAssertTrue(plan.classpath.contains(appClasses.path), "\(plan.classpath)")
        XCTAssertTrue(plan.classpath.contains(stubJar.path), "\(plan.classpath)")

        // 冷启动只启动一次 Gradle：编译与 classpath 解析在同一次调用里完成。
        let log = try String(contentsOf: root.appendingPathComponent("gradlew.log"), encoding: .utf8)
        let invocations = log.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(invocations.count, 1, "应合并为一次 Gradle 调用：\n\(log)")
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertTrue(invocation.contains(":app:classes"), invocation)
        XCTAssertTrue(invocation.contains(":app:ideaLightRunClasspath"), invocation)
        XCTAssertTrue(invocation.contains("--no-daemon"), invocation)
        XCTAssertTrue(invocation.contains("--init-script"), invocation)

        let cached = ClasspathCache.load(
            projectRoot: root,
            variant: .gradle(module: ":app", includeProvided: false)
        )
        XCTAssertEqual(cached?.entries, [appClasses.path, stubJar.path])
    }
}
