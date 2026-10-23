import XCTest
@testable import IdeaLightRunCore

final class HotReloadConfigurationTests: XCTestCase {
    func testDefaultIsDisabledAndNormalizationClampsDebounce() {
        let configuration = HotReloadConfiguration()
        XCTAssertFalse(configuration.isActive)
        XCTAssertEqual(configuration.provider, .automatic)
        XCTAssertEqual(configuration.restartPolicy, .ask)

        var custom = configuration
        custom.enabled = true
        custom.debounceMilliseconds = 5
        custom.ignoredPaths = ["  target  ", "", "  "]
        let normalized = custom.normalized
        XCTAssertEqual(normalized.debounceMilliseconds, 200)
        XCTAssertEqual(normalized.ignoredPaths, ["target"])
        XCTAssertEqual(normalized.effectiveDebounce, 0.2, accuracy: 0.000_1)

        custom.debounceMilliseconds = 60_000
        XCTAssertEqual(custom.normalized.debounceMilliseconds, 10_000)
    }

    func testStandardCapabilityOnlyClaimsMethodBodySupport() {
        let capability = HotReloadProviderKind.standard.staticCapability
        XCTAssertEqual(capability.provider, .standard)
        XCTAssertEqual(capability.methodBody, .supported)
        XCTAssertEqual(capability.structuralChanges, .unsupported)
        XCTAssertEqual(capability.springBeanRefresh, .unsupported)
        XCTAssertFalse(capability.structuralChanges.isDirectlySupported)
    }

    func testDevToolsIsRestartNotHotSwap() {
        let capability = HotReloadProviderKind.springBootDevTools.staticCapability
        guard case .restart = capability.methodBody else {
            return XCTFail("DevTools 必须标为快速重启，不能宣称方法体热替换")
        }
        guard case .restart = capability.structuralChanges else {
            return XCTFail("DevTools 的结构变更也应标为重启")
        }
        XCTAssertFalse(capability.methodBody.isDirectlySupported)
    }

    func testExternalAgentsAreDelegatedAndNotClaimed() {
        for kind in [HotReloadProviderKind.hotswapAgent, .jrebel] {
            let capability = kind.staticCapability
            XCTAssertEqual(capability.methodBody, .delegated)
            XCTAssertEqual(capability.structuralChanges, .delegated)
            XCTAssertFalse(capability.methodBody.isDirectlySupported)
            XCTAssertTrue(kind.isExternalAgent)
        }
        XCTAssertFalse(HotReloadProviderKind.standard.isExternalAgent)
    }

    func testAutomaticProviderPrefersDevToolsOnlyWhenPresent() {
        XCTAssertEqual(
            HotReloadPlanner.resolveProvider(.automatic, devToolsDetected: false),
            .standard
        )
        XCTAssertEqual(
            HotReloadPlanner.resolveProvider(.automatic, devToolsDetected: true),
            .springBootDevTools
        )
        XCTAssertEqual(
            HotReloadPlanner.resolveProvider(.standard, devToolsDetected: true),
            .standard
        )
    }

    func testSplitArgumentsKeepsQuotesAndEscapesWithoutShell() {
        let raw = #"-javaagent:"/opt/my agent.jar" -Dname="hello world" -Dpath='C:\\temp' --add-opens=java.base/java.lang=ALL-UNNAMED"#
        XCTAssertEqual(
            HotReloadPlanner.splitArguments(raw),
            [
                "-javaagent:/opt/my agent.jar",
                "-Dname=hello world",
                "-Dpath=C:\\temp",
                "--add-opens=java.base/java.lang=ALL-UNNAMED"
            ]
        )
        XCTAssertEqual(HotReloadPlanner.splitArguments("   "), [])
    }

    func testFailureClassificationIsHonestAboutSchemaChanges() {
        XCTAssertEqual(
            HotReloadFailureKind.classify("attempted to change the schema of class demo.App"),
            .schemaChange
        )
        XCTAssertEqual(
            HotReloadFailureKind.classify("class is not modifiable"),
            .notModifiable
        )
        XCTAssertEqual(
            HotReloadFailureKind.classify("class not loaded yet"),
            .notLoaded
        )
        XCTAssertEqual(
            HotReloadFailureKind.classify("java.lang.VerifyError: bad type"),
            .bytecodeRejected
        )
        XCTAssertEqual(
            HotReloadFailureKind.classify("connection refused"),
            .agentUnreachable
        )
        XCTAssertTrue(HotReloadFailureKind.schemaChange.requiresEnhancedAgentOrRestart)
        XCTAssertTrue(HotReloadFailureKind.classRemoved.requiresEnhancedAgentOrRestart)
        XCTAssertFalse(HotReloadFailureKind.notLoaded.requiresEnhancedAgentOrRestart)
    }

    func testDisabledSnapshotSaysDisabled() {
        let snapshot = HotReloadSnapshot.disabled()
        XCTAssertEqual(snapshot.state, .disabled)
        XCTAssertFalse(snapshot.configuration.enabled)
        XCTAssertFalse(snapshot.canManualTrigger)
    }

    func testAgentLocatorUsesEnvironmentOverrideAndRejectsEmptyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hot-reload-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let jar = directory.appendingPathComponent("HotReloadAgent.jar")
        try Data("agent".utf8).write(to: jar)

        let located = HotReloadAgentLocator.locate(
            environment: [HotReloadAgentLocator.environmentKey: jar.path],
            executableURL: nil,
            bundleResourceURL: nil,
            currentDirectory: directory
        )
        XCTAssertEqual(located?.path, jar.standardizedFileURL.path)

        let emptyJar = directory.appendingPathComponent("Empty.jar")
        try Data().write(to: emptyJar)
        let missing = HotReloadAgentLocator.locate(
            environment: [HotReloadAgentLocator.environmentKey: emptyJar.path],
            executableURL: nil,
            bundleResourceURL: nil,
            currentDirectory: directory.appendingPathComponent("nowhere")
        )
        XCTAssertNil(missing)
    }

    func testAgentLaunchCreatesPrivateControlFilesAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hot-reload-agent-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let jar = directory.appendingPathComponent("HotReloadAgent.jar")
        try Data("agent".utf8).write(to: jar)

        let launch = try HotReloadAgentLaunch.prepare(jarURL: jar)
        defer { launch.cleanup() }

        XCTAssertEqual(launch.token.count, 64)
        XCTAssertTrue(launch.token.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(launch.jvmArguments.count, 1)
        let argument = try XCTUnwrap(launch.jvmArguments.first)
        XCTAssertTrue(argument.hasPrefix("-javaagent:\(jar.path)="))
        XCTAssertTrue(argument.contains("portFile=\(launch.portFileURL.path)"))
        XCTAssertTrue(argument.contains("tokenFile=\(launch.tokenFileURL.path)"))
        XCTAssertFalse(argument.contains(launch.token), "凭据不能出现在 JVM 参数里")

        let directoryPermissions = try FileManager.default
            .attributesOfItem(atPath: launch.controlDirectory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        let tokenPermissions = try FileManager.default
            .attributesOfItem(atPath: launch.tokenFileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(tokenPermissions?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.portFileURL.path))

        launch.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.controlDirectory.path))
    }
}
