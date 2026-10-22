import XCTest
@testable import IdeaLightRunCore

/// §P0-5: 可运行性只在 Core 计算一次。这些用例同时钉住三件事：
/// 类型能力、项目构建系统选择、以及会阻止启动的字段/任务缺口。
final class ConfigurationCapabilityResolverTests: XCTestCase {
    private let projectRoot = URL(fileURLWithPath: "/tmp/lr-capability-project", isDirectory: true)

    private func config(
        _ type: RunConfigurationType,
        name: String = "Cfg",
        mainClass: String? = "com.example.App",
        jarPath: String? = nil,
        moduleName: String? = "app",
        beforeLaunch: [BeforeLaunchTask] = [],
        warnings: [ConfigurationWarning] = []
    ) -> RunConfiguration {
        RunConfiguration(
            name: name,
            type: type,
            mainClass: mainClass,
            jarPath: jarPath,
            moduleName: moduleName,
            beforeLaunchTasks: beforeLaunch,
            source: ConfigurationSource(
                kind: .dotRun,
                file: URL(fileURLWithPath: "/tmp/\(name).run.xml"),
                modifiedAt: nil
            ),
            warnings: warnings
        )
    }

    private func scan(
        maven: Bool = true,
        gradle: Bool = false,
        modules: [ProjectModule] = [],
        configurations: [RunConfiguration] = []
    ) -> ScanResult {
        ScanResult(
            projectRoot: projectRoot,
            configurations: configurations,
            ignoredDuplicateCount: 0,
            buildSystem: BuildSystemDetection(
                maven: maven
                    ? MavenDetection(pomURL: projectRoot.appendingPathComponent("pom.xml"), wrapperURL: nil)
                    : nil,
                gradle: gradle
                    ? GradleDetection(
                        settingsURL: projectRoot.appendingPathComponent("settings.gradle.kts"),
                        buildFileURL: nil,
                        wrapperURL: nil,
                        usesKotlinDSL: true
                    )
                    : nil
            ),
            projectJDKName: nil,
            modules: modules
        )
    }

    // MARK: - 类型与字段

    func testApplicationInMavenProjectIsReady() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application),
            scan: scan(modules: [ProjectModule(name: "app", directory: projectRoot, artifactId: "app")])
        )
        XCTAssertEqual(capability.readiness, .ready)
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertEqual(capability.buildSystem, .maven)
        XCTAssertTrue(capability.blockingIssues.isEmpty, "\(capability.blockingIssues)")
    }

    func testMissingMainClassBlocksLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.springBoot, mainClass: nil),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertFalse(capability.isLaunchable)
        XCTAssertTrue(capability.missingFields.contains("Main Class"))
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Main Class") })
    }

    /// 显式写了 Module 却既匹配不到、也无法按 Main Class 定位：启动必然失败，
    /// 徽标不能还显示 READY。
    func testUnresolvableModuleBlocksLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application, moduleName: "ghost"),
            scan: scan(modules: [ProjectModule(name: "app", directory: projectRoot, artifactId: "app")])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("ghost") })
    }

    /// 按 Main Class 兜底成功仍可启动，但必须告知用户 module 名对不上。
    func testModuleFallbackProducesWarning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-module-fallback-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("src/main/java/com/example", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "final class App {}".write(
            to: sourceDirectory.appendingPathComponent("App.java"),
            atomically: true,
            encoding: .utf8
        )
        try "<project/>".write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application, moduleName: "ghost"),
            scan: ScanResult(
                projectRoot: root,
                configurations: [],
                ignoredDuplicateCount: 0,
                buildSystem: BuildSystemDetection(
                    maven: MavenDetection(pomURL: root.appendingPathComponent("pom.xml"), wrapperURL: nil)
                ),
                projectJDKName: nil,
                modules: [ProjectModule(name: "app", directory: root, artifactId: "app")]
            )
        )
        XCTAssertEqual(capability.readiness, .warning)
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertTrue(capability.warningIssues.contains { $0.contains("ghost") })
    }

    func testPlannedAndUnsupportedTypes() {
        let planned: [RunConfigurationType] = [.maven, .gradle]
        for type in planned {
            let capability = ConfigurationCapabilityResolver.resolve(config(type), scan: scan())
            XCTAssertEqual(capability.readiness, .planned, "\(type)")
            XCTAssertFalse(capability.isLaunchable, "\(type)")
        }

        let unsupported: [RunConfigurationType] = [.junit, .unknown("TestNG")]
        for type in unsupported {
            let capability = ConfigurationCapabilityResolver.resolve(config(type), scan: scan())
            XCTAssertEqual(capability.readiness, .unsupported, "\(type)")
            XCTAssertFalse(capability.isLaunchable, "\(type)")
        }
    }

    // MARK: - Compound

    private func compound(
        name: String = "All",
        members: [CompoundMember],
        beforeLaunch: [BeforeLaunchTask] = []
    ) -> RunConfiguration {
        var config = config(.compound, name: name, mainClass: nil, moduleName: nil, beforeLaunch: beforeLaunch)
        config.compoundMembers = members
        return config
    }

    private func member(_ name: String, _ type: RunConfigurationType = .application) -> CompoundMember {
        CompoundMember(name: name, type: type.ideaTypeRaw)
    }

    private let modules = [ProjectModule(
        name: "app",
        directory: URL(fileURLWithPath: "/tmp/lr-capability-project", isDirectory: true),
        artifactId: "app"
    )]

    func testCompoundWithValidMembersIsReady() {
        let one = config(.application, name: "One")
        let two = config(.application, name: "Two")
        let all = compound(members: [member("One"), member("Two")])

        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(modules: modules, configurations: [one, two, all])
        )

        XCTAssertEqual(capability.readiness, .ready)
        XCTAssertTrue(capability.isLaunchable, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.blockingIssues.isEmpty, "\(capability.blockingIssues)")
    }

    func testEmptyCompoundBlocksLaunch() {
        let all = compound(members: [])
        let capability = ConfigurationCapabilityResolver.resolve(all, scan: scan(configurations: [all]))
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertFalse(capability.isLaunchable)
        XCTAssertTrue(capability.missingFields.contains("Compound 成员"))
    }

    func testCompoundMissingMemberBlocksLaunch() {
        let all = compound(members: [member("Ghost")])
        let capability = ConfigurationCapabilityResolver.resolve(all, scan: scan(configurations: [all]))
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Ghost") && $0.contains("不存在") })
    }

    func testCompoundMemberTypeMismatchBlocksLaunch() {
        // 同名配置有两种类型时不能按名字任选一个，必须提示类型不匹配。
        let boot = config(.springBoot, name: "Same")
        let jar = config(.jar, name: "Same", mainClass: nil, jarPath: "same.jar")
        let all = compound(members: [member("Same", .application)])
        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(modules: modules, configurations: [boot, jar, all])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("类型") }, "\(capability.blockingIssues)")
    }

    /// IDEA 的 toRun 按名字找成员：配置类型改过之后旧 type 会过期，
    /// 只要同名配置唯一，仍应指向用户当初选的那个配置。
    func testCompoundStaleTypeFallsBackToUniqueName() {
        let app = config(.application, name: "One")
        let all = compound(members: [member("One", .springBoot)])
        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(modules: modules, configurations: [app, all])
        )
        XCTAssertEqual(capability.readiness, .ready, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.isLaunchable)
    }

    /// 成员本身不能启动（Maven 配置仍是 planned）时，Compound 不能显示 READY。
    func testCompoundUnsupportedMemberBlocksLaunch() {
        let maven = config(.maven, name: "Build")
        let all = compound(members: [member("Build", .maven)])
        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(configurations: [maven, all])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Build") }, "\(capability.blockingIssues)")
    }

    func testCompoundCycleBlocksLaunch() {
        let a = compound(name: "A", members: [member("B", .compound)])
        let b = compound(name: "B", members: [member("A", .compound)])
        let capability = ConfigurationCapabilityResolver.resolve(
            a,
            scan: scan(configurations: [a, b])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("循环") }, "\(capability.blockingIssues)")
    }

    func testNestedCompoundWithValidLeavesIsReady() {
        let one = config(.application, name: "One")
        let nested = compound(name: "Nested", members: [member("One")])
        let all = compound(name: "All", members: [member("Nested", .compound)])
        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(modules: modules, configurations: [one, nested, all])
        )
        XCTAssertEqual(capability.readiness, .ready, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.isLaunchable)
    }

    /// 嵌套展开后同一个叶子配置出现两次，启动时会变成两个进程。
    func testNestedCompoundDuplicateLeafBlocksLaunch() {
        let one = config(.application, name: "One")
        let nested = compound(name: "Nested", members: [member("One")])
        let all = compound(name: "All", members: [member("Nested", .compound), member("One")])
        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(modules: modules, configurations: [one, nested, all])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("重复引用") }, "\(capability.blockingIssues)")
    }

    func testCompoundOwnBeforeLaunchBlocksLaunch() {
        let one = config(.application, name: "One")
        let all = compound(
            members: [member("One")],
            beforeLaunch: [BeforeLaunchTask(kind: .build, isEnabled: true)]
        )
        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(modules: modules, configurations: [one, all])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Before Launch") }, "\(capability.blockingIssues)")
    }

    /// 成员的提示（如 JAR 暂不存在）要冒泡到 Compound，不能显示成完全无警告。
    func testCompoundMemberWarningBubblesUp() {
        let jar = config(.jar, name: "Jar", mainClass: nil, jarPath: "target/missing.jar", moduleName: nil)
        let all = compound(members: [member("Jar", .jar)])
        let capability = ConfigurationCapabilityResolver.resolve(
            all,
            scan: scan(configurations: [jar, all])
        )
        XCTAssertEqual(capability.readiness, .warning, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.isLaunchable)
    }

    // MARK: - JAR Application

    private func makeJarFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-jar-capability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jar = directory.appendingPathComponent("app.jar")
        try Data("PK".utf8).write(to: jar)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return jar
    }

    func testJarWithoutPathBlocksLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.jar, mainClass: nil),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertFalse(capability.isLaunchable)
        XCTAssertTrue(capability.missingFields.contains("JAR Path"))
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("JAR Path") })
    }

    /// JAR 启动只需要 java -jar：没有构建系统也不影响。
    func testJarWithExistingFileIsReadyWithoutBuildSystem() throws {
        let jar = try makeJarFile()
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.jar, mainClass: nil, jarPath: jar.path),
            scan: scan(maven: false, gradle: false)
        )
        XCTAssertEqual(capability.readiness, .ready)
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertNil(capability.buildSystem)
    }

    /// IDEA 对不存在的 JAR 只给 RuntimeConfigurationWarning：Before Launch 可能先产出它。
    func testJarWithMissingFileOnlyWarns() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.jar, mainClass: nil, jarPath: "target/app.jar"),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .warning)
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertTrue(capability.warningIssues.contains { $0.contains("JAR 文件当前不存在") })
    }

    /// 只要 Before Launch 里有构建类任务，就必须有可用的构建系统。
    func testJarBeforeLaunchBuildRequiresBuildSystem() throws {
        let jar = try makeJarFile()
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .jar,
                mainClass: nil,
                jarPath: jar.path,
                beforeLaunch: [BeforeLaunchTask(kind: .build, isEnabled: true)]
            ),
            scan: scan(maven: false, gradle: false, modules: modules)
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertFalse(capability.isLaunchable)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("构建系统") }, "\(capability.blockingIssues)")
    }

    /// M4：Gradle 项目里的 JAR 配置同样可以靠 Before Launch Build 产出/编译。
    func testJarBeforeLaunchBuildIsReadyInGradleProject() throws {
        let jar = try makeJarFile()
        let gradleModule = ProjectModule(name: "app", directory: projectRoot, gradlePath: ":app")
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .jar,
                mainClass: nil,
                jarPath: jar.path,
                beforeLaunch: [BeforeLaunchTask(kind: .build, isEnabled: true)]
            ),
            scan: scan(maven: false, gradle: true, modules: [gradleModule])
        )
        XCTAssertEqual(capability.readiness, .ready, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertEqual(capability.buildSystem, .gradle)
    }

    func testJarBeforeLaunchBuildRequiresResolvableModule() throws {
        let jar = try makeJarFile()
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .jar,
                mainClass: nil,
                jarPath: jar.path,
                beforeLaunch: [BeforeLaunchTask(kind: .build, isEnabled: true)]
            ),
            scan: scan(modules: [])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Module") })
    }

    /// 没有构建类 Before Launch 时，Gradle 项目也能启动已经打好的 JAR。
    func testJarInGradleProjectIsReadyWithoutBuildTasks() throws {
        let jar = try makeJarFile()
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.jar, mainClass: nil, jarPath: jar.path),
            scan: scan(maven: false, gradle: true)
        )
        XCTAssertEqual(capability.readiness, .ready)
        XCTAssertTrue(capability.isLaunchable)
    }

    func testWarningsKeepConfigurationLaunchable() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                warnings: [.unresolvedMacro(token: "$UNKNOWN$", rawValue: "$UNKNOWN$")]
            ),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .warning)
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertFalse(capability.warningIssues.isEmpty)
    }

    // MARK: - 构建系统选择

    /// M4：只有 Gradle 的项目现在可以启动，徽标必须给出 Gradle 构建系统。
    func testGradleOnlyProjectIsReadyWithBuildSystemRecorded() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application),
            scan: scan(maven: false, gradle: true)
        )
        XCTAssertEqual(capability.readiness, .ready)
        XCTAssertEqual(capability.buildSystem, .gradle)
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertTrue(capability.blockingIssues.isEmpty, "\(capability.blockingIssues)")
    }

    func testMissingBuildSystemBlocksLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application),
            scan: scan(maven: false, gradle: false)
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertNil(capability.buildSystem)
        XCTAssertFalse(capability.isLaunchable)
    }

    /// 双构建系统：模块目录里的构建脚本是归属证据。
    func testDualBuildSystemUsesModuleEvidence() throws {
        let moduleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-gradle-module-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
        try Data().write(to: moduleDirectory.appendingPathComponent("build.gradle.kts"))
        defer { try? FileManager.default.removeItem(at: moduleDirectory) }

        let modules = [ProjectModule(name: "server", directory: moduleDirectory, gradlePath: ":server")]
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application, moduleName: "server"),
            scan: scan(maven: true, gradle: true, modules: modules)
        )

        XCTAssertEqual(capability.buildSystem, .gradle)
        XCTAssertEqual(capability.readiness, .ready, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.isLaunchable)
    }

    /// 双构建系统且无模块归属证据：固定回退 Maven，但必须显示歧义警告。
    func testDualBuildSystemWithoutEvidenceFallsBackToMavenWithWarning() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application, moduleName: nil),
            scan: scan(maven: true, gradle: true)
        )
        XCTAssertEqual(capability.buildSystem, .maven)
        XCTAssertEqual(capability.readiness, .warning)
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertTrue(capability.warningIssues.contains { $0.contains("同时存在 Maven 与 Gradle") })
    }

    func testTypeSpecificBuildSystemIsNeverCrossed() {
        let both = BuildSystemDetection(
            maven: MavenDetection(pomURL: projectRoot.appendingPathComponent("pom.xml"), wrapperURL: nil),
            gradle: GradleDetection(
                settingsURL: projectRoot.appendingPathComponent("settings.gradle"),
                buildFileURL: nil,
                wrapperURL: nil,
                usesKotlinDSL: false
            )
        )
        XCTAssertEqual(
            BuildSystemSelector.select(config: config(.maven), detection: both).kind,
            .maven
        )
        XCTAssertEqual(
            BuildSystemSelector.select(config: config(.gradle), detection: both).kind,
            .gradle
        )

        let gradleOnly = BuildSystemDetection(
            gradle: GradleDetection(
                settingsURL: projectRoot.appendingPathComponent("settings.gradle"),
                buildFileURL: nil,
                wrapperURL: nil,
                usesKotlinDSL: false
            )
        )
        let missingMaven = BuildSystemSelector.select(config: config(.maven), detection: gradleOnly)
        XCTAssertNil(missingMaven.kind)
        XCTAssertTrue(missingMaven.reason.contains("pom.xml"))
    }

    // MARK: - Before Launch

    func testUnsupportedBeforeLaunchTaskBlocksLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .unknown(raw: "BuildArtifacts"), isEnabled: true)]
            ),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.unsupportedBeforeLaunchTasks.contains("BuildArtifacts"))
        XCTAssertFalse(capability.isLaunchable)
    }

    /// 任务类型与项目构建系统错配时必须拦住：把 Gradle task 交给 Maven 会把任务静默换成另一套语义。
    func testGradleBeforeLaunchTaskBlocksMavenLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .gradleTask(task: "classes"), isEnabled: true)]
            ),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Gradle") }, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.unsupportedBeforeLaunchTasks.isEmpty, "Gradle 任务已支持，不应再计入“不支持的任务”")
    }

    func testMavenBeforeLaunchTaskBlocksGradleLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .mavenGoal(goal: "clean", pomFile: nil), isEnabled: true)]
            ),
            scan: scan(maven: false, gradle: true)
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Maven") }, "\(capability.blockingIssues)")
    }

    /// M4：Gradle 项目与 Gradle Before Launch 任务同源时可以启动。
    func testGradleBeforeLaunchTaskIsReadyInGradleProject() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .gradleTask(task: "bootJar"), isEnabled: true)]
            ),
            scan: scan(maven: false, gradle: true)
        )
        XCTAssertEqual(capability.readiness, .ready, "\(capability.blockingIssues)")
        XCTAssertTrue(capability.isLaunchable)
        XCTAssertEqual(capability.buildSystem, .gradle)
    }

    func testEmptyGradleBeforeLaunchTaskBlocksLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .gradleTask(task: " "), isEnabled: true)]
            ),
            scan: scan(maven: false, gradle: true)
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.missingFields.contains("Gradle task"))
    }

    func testEmptyMavenBeforeLaunchGoalBlocksLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .mavenGoal(goal: "  ", pomFile: nil), isEnabled: true)]
            ),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.missingFields.contains("Maven goal"))
    }

    func testDisabledTasksAreIgnored() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .unknown(raw: "BuildArtifacts"), isEnabled: false)]
            ),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .ready)
        XCTAssertTrue(capability.isLaunchable)
    }

    func testMissingReferencedConfigurationBlocksLaunch() {
        let source = config(
            .application,
            name: "Source",
            beforeLaunch: [
                BeforeLaunchTask(kind: .runConfiguration(name: "Missing", type: "Application"), isEnabled: true)
            ]
        )
        let capability = ConfigurationCapabilityResolver.resolve(
            source,
            scan: scan(configurations: [source])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Missing") })
    }

    func testSameNameDifferentTypeReferenceIsNotSilentlyAccepted() {
        let other = config(.springBoot, name: "Build", moduleName: "app")
        let source = config(
            .application,
            name: "Source",
            beforeLaunch: [
                BeforeLaunchTask(kind: .runConfiguration(name: "Build", type: "Application"), isEnabled: true)
            ]
        )
        let capability = ConfigurationCapabilityResolver.resolve(
            source,
            scan: scan(configurations: [source, other])
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("类型") })
    }
}
