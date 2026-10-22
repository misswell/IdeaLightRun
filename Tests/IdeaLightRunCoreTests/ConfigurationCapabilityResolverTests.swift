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
        let planned: [RunConfigurationType] = [.compound, .maven, .gradle]
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

    /// 只要 Before Launch 里有 Build / Build Project / Maven goal，就必须有可用的 Maven。
    func testJarBeforeLaunchBuildRequiresMaven() throws {
        let jar = try makeJarFile()
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .jar,
                mainClass: nil,
                jarPath: jar.path,
                beforeLaunch: [BeforeLaunchTask(kind: .build, isEnabled: true)]
            ),
            scan: scan(maven: false, gradle: true)
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertFalse(capability.isLaunchable)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Maven") })
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

    func testGradleOnlyProjectIsPlannedWithBuildSystemRecorded() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(.application),
            scan: scan(maven: false, gradle: true)
        )
        XCTAssertEqual(capability.readiness, .planned)
        XCTAssertEqual(capability.buildSystem, .gradle)
        XCTAssertFalse(capability.isLaunchable)
        XCTAssertTrue(capability.blockingIssues.contains { $0.contains("Gradle") })
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
        XCTAssertEqual(capability.readiness, .planned)
        XCTAssertFalse(capability.isLaunchable)
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

    func testGradleBeforeLaunchTaskBlocksMavenLaunch() {
        let capability = ConfigurationCapabilityResolver.resolve(
            config(
                .application,
                beforeLaunch: [BeforeLaunchTask(kind: .gradleTask(task: "classes"), isEnabled: true)]
            ),
            scan: scan()
        )
        XCTAssertEqual(capability.readiness, .unsupported)
        XCTAssertTrue(capability.unsupportedBeforeLaunchTasks.contains { $0.contains("classes") })
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
