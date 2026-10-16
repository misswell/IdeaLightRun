import XCTest
@testable import IdeaLightRunCore

/// §P0-10: SHORTEN_COMMAND_LINE——超长 classpath 不能被 execve 的 E2BIG 拒掉，
/// 也不能悄悄改变语义。三种载体（原样 / @argfile / manifest jar）+ 临时产物生命周期。
final class ShortenCommandLineTests: XCTestCase {
    let projectRoot = Fixtures.url("MavenMultiProject")

    override func setUpWithError() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightrun-fake-jdk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let java = home.appendingPathComponent("bin/java")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: java)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        fakeJavaHome = home
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home)
        }
    }

    override func tearDown() {
        ClasspathCache.clear(projectRoot: projectRoot, moduleName: "gateway")
    }

    private var fakeJavaHome: URL!

    private func makeJDK(major: Int?) -> JDKInstallation {
        JDKInstallation(home: fakeJavaHome, majorVersion: major)
    }

    private func makeConfig(shorten: String?) -> RunConfiguration {
        var config = RunConfiguration(
            name: "GatewayApplication",
            type: .springBoot,
            mainClass: "com.example.gateway.GatewayApplication",
            moduleName: "gateway",
            source: ConfigurationSource(kind: .dotRun, file: projectRoot, modifiedAt: nil)
        )
        if let shorten {
            config.rawOptions["SHORTEN_COMMAND_LINE"] = shorten
        }
        return config
    }

    private func plan(shorten: String?, classpath: [String], jdkMajor: Int? = 17) throws -> ExecutableLaunchPlan {
        let resolved = try RunConfigurationResolver().resolve(
            config: makeConfig(shorten: shorten),
            projectRoot: projectRoot,
            module: ProjectModule(
                name: "gateway",
                directory: projectRoot.appendingPathComponent("gateway", isDirectory: true)
            ),
            jdk: makeJDK(major: jdkMajor)
        )
        return try JavaRunPlanner.plan(resolved: resolved, classpath: classpath, jdk: makeJDK(major: jdkMajor))
    }

    private func classpathEntry(count: Int) -> [String] {
        (0..<count).map { "/tmp/dependency-\($0)/some-library-\($0)-1.0.0.jar" }
    }

    // MARK: - 模式解析

    func testParseRecognisesIdeaValues() {
        XCTAssertEqual(ShortenCommandLineMode.parse("NONE"), .none)
        XCTAssertEqual(ShortenCommandLineMode.parse("JAR_MANIFEST"), .jarManifest)
        XCTAssertEqual(ShortenCommandLineMode.parse("CLASSPATH_FILE"), .classpathFile)
        XCTAssertEqual(ShortenCommandLineMode.parse("ARGFILE"), .classpathFile)
        XCTAssertEqual(ShortenCommandLineMode.parse("AUTO"), .auto)
        XCTAssertEqual(ShortenCommandLineMode.parse(nil), .auto)
        // 未知值按 auto 兜底，不会把超长 classpath 送进 E2BIG
        XCTAssertEqual(ShortenCommandLineMode.parse("SOMETHING_NEW"), .auto)
    }

    // MARK: - NONE

    func testNoneKeepsPlainClasspathEvenWhenVeryLong() throws {
        let classpath = classpathEntry(count: 900) // ≈ 5 万+ 字符
        let plan = try plan(shorten: "NONE", classpath: classpath)
        guard let dash = plan.arguments.firstIndex(of: "-cp") else {
            return XCTFail("NONE 模式必须有 -cp：\(plan.arguments.prefix(4))")
        }
        XCTAssertEqual(plan.arguments[dash + 1], classpath.joined(separator: ":"))
        XCTAssertTrue(plan.temporaryArtifacts.isEmpty)
    }

    // MARK: - ARGFILE / CLASSPATH_FILE

    func testArgfileCarriesClasspathAndMainClassStaysOnCommandLine() throws {
        let classpath = classpathEntry(count: 50)
        for mode in ["ARGFILE", "CLASSPATH_FILE"] {
            let plan = try plan(shorten: mode, classpath: classpath)
            defer { plan.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) } }

            guard let argfile = plan.arguments.first(where: { $0.hasPrefix("@") }) else {
                return XCTFail("\(mode) 必须以 @argfile 传递：\(plan.arguments.prefix(4))")
            }
            let path = String(argfile.dropFirst())
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(mode)：argfile 必须真实存在")
            XCTAssertEqual(plan.temporaryArtifacts, [URL(fileURLWithPath: path)], "\(mode)：argfile 要登记为临时产物")

            let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            XCTAssertTrue(
                content.hasPrefix("-cp \"") && content.hasSuffix("\""),
                "argfile 应是 -cp \"<classpath>\"，实际：\(content.prefix(60))…"
            )
            let inner = content.dropFirst("-cp \"".count).dropLast()
            XCTAssertEqual(String(inner), classpath.joined(separator: ":"))
            // main class 与程序参数仍留在命令行上
            XCTAssertTrue(plan.arguments.contains("com.example.gateway.GatewayApplication"))
        }
    }

    // MARK: - AUTO

    func testAutoKeepsShortClasspathPlain() throws {
        let plan = try plan(shorten: "AUTO", classpath: ["/tmp/a.jar", "/tmp/b.jar"])
        XCTAssertTrue(plan.arguments.contains("-cp"))
        XCTAssertFalse(plan.arguments.contains { $0.hasPrefix("@") })
        XCTAssertTrue(plan.temporaryArtifacts.isEmpty)
    }

    func testAutoSwitchesToArgfileForLongClasspathOnModernJDK() throws {
        let classpath = classpathEntry(count: 1_500) // ≈ 8 万字符，超过阈值
        XCTAssertTrue(classpath.joined(separator: ":").count > ShortenCommandLineMode.autoThreshold)

        let plan = try plan(shorten: "AUTO", classpath: classpath, jdkMajor: 17)
        defer { plan.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertTrue(plan.arguments.contains { $0.hasPrefix("@") }, "JDK 17 的 AUTO 长classpath 应走 @argfile")
    }

    /// JDK 8 没有 @argfile（JDK 9+ 语法），AUTO 必须退到 manifest jar。
    func testAutoFallsBackToManifestJarOnLegacyJDK() throws {
        let classpath = classpathEntry(count: 1_500)
        let plan = try plan(shorten: "AUTO", classpath: classpath, jdkMajor: 8)
        defer { plan.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) } }

        guard let dash = plan.arguments.firstIndex(of: "-cp") else {
            return XCTFail("JDK 8 的 AUTO 应退到 -cp <manifest jar>：\(plan.arguments.prefix(4))")
        }
        let jarPath = plan.arguments[dash + 1]
        XCTAssertEqual(jarPath, plan.temporaryArtifacts.first?.path)
        XCTAssertTrue(jarPath.hasSuffix(".jar"))
    }

    // MARK: - JAR_MANIFEST

    func testJarManifestIsAValidZipWithClassPath() throws {
        let classpath = ["/tmp/with space/lib a.jar", "/tmp/plain/b.jar", "/tmp/classes"]
        let plan = try plan(shorten: "JAR_MANIFEST", classpath: classpath)
        defer { plan.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) } }

        guard let dash = plan.arguments.firstIndex(of: "-cp") else {
            return XCTFail("JAR_MANIFEST 必须有 -cp：\(plan.arguments.prefix(4))")
        }
        let jarPath = plan.arguments[dash + 1]
        XCTAssertEqual(jarPath, plan.temporaryArtifacts.first?.path, "manifest jar 必须登记为临时产物")
        XCTAssertTrue(plan.arguments.contains("com.example.gateway.GatewayApplication"))

        let bytes = try Data(contentsOf: URL(fileURLWithPath: jarPath))
        // zip 结构：local header、条目名、central directory、EOCD
        XCTAssertEqual([UInt8](bytes.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "local file header 签名")
        XCTAssertTrue(bytes.range(of: Data("META-INF/MANIFEST.MF".utf8)) != nil)
        // manifest 是 stored 原文：把续行拼回去再断言条目（续行可能落在任意条目中间）
        let unfolded = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(unfolded.contains("Class-Path: file:/tmp/with%20space/lib%20a.jar"),
                      "空格要百分号编码：\(unfolded.filter { $0.isASCII })")
        XCTAssertTrue(unfolded.contains("file:/tmp/plain/b.jar"))
        XCTAssertTrue(unfolded.contains("file:/tmp/classes"), "目录条目同样进 Class-Path")
        XCTAssertTrue(bytes.range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil, "EOCD 签名")
    }

    /// JAR 规范：manifest 行（含续行）最长 72 字节，续行以单个空格开头。
    func testManifestLinesAreFoldedToAtMost72Bytes() {
        let content = String(
            decoding: ManifestClasspathJar.manifestContent(classpath: classpathEntry(count: 120)),
            as: UTF8.self
        )
        for line in content.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 72, "超长行：\(line.prefix(80))…")
        }
        XCTAssertTrue(content.hasSuffix("\r\n"), "manifest 以换行结束")
    }

    func testManifestEntriesAreURLEncoded() {
        let data = ManifestClasspathJar.manifestContent(classpath: ["/tmp/中文 目录/a.jar"])
        let content = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(content.contains("中文"), "非 ASCII 必须 URL 编码")
        XCTAssertTrue(content.contains("file:/tmp/%E4%B8%AD%E6%96%87%20%E7%9B%AE%E5%BD%95/a.jar"))
    }

    // MARK: - 临时产物孤儿清理

    func testOrphanCleanupRemovesOnlyOldArtifacts() throws {
        try FileManager.default.createDirectory(at: LaunchArtifactStore.directory, withIntermediateDirectories: true)
        let old = LaunchArtifactStore.directory.appendingPathComponent("orphan-old.argfile")
        let fresh = LaunchArtifactStore.directory.appendingPathComponent("in-use.argfile")
        try Data("-cp /tmp/x".utf8).write(to: old)
        try Data("-cp /tmp/y".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7 * 3600)],
            ofItemAtPath: old.path
        )
        defer { try? FileManager.default.removeItem(at: fresh) }

        LaunchArtifactStore.cleanupOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "超过 6 小时的遗留产物要清掉")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "正在使用的产物不能误删")
    }

    // MARK: - 真实 JVM 验收

    /// 手写的 zip 结构是否合法，最终裁判是 JVM：manifest jar 能被 java -cp 读进
    /// classpath（类不存在 → "Could not find or load main class"；
    /// jar 损坏 → "Invalid or corrupt jarfile"）。
    func testRealJVMAcceptsManifestJar() throws {
        try XCTSkipIf(TestToolchain.availableJDK() == nil, "系统没有可用 JDK")
        let plan = try plan(shorten: "JAR_MANIFEST", classpath: ["/tmp/a.jar", "/tmp/b.jar"])
        defer { plan.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) } }
        guard let dash = plan.arguments.firstIndex(of: "-cp") else {
            return XCTFail("缺少 -cp")
        }

        let output = try runJava(arguments: ["-cp", plan.arguments[dash + 1], "com.example.DoesNotExist"])
        // 输出按系统语言本地化（"Could not find or load main class" / "找不到或无法加载主类"），
        // 断言只依赖类名被报出（= jar 已被读进 classpath）与没有损坏/拒绝字样。
        XCTAssertTrue(output.contains("com.example.DoesNotExist"), "类名应出现在报错里（jar 已被接受），实际输出：\(output)")
        XCTAssertFalse(
            output.lowercased().contains("corrupt") || output.contains("无效或损坏"),
            "jar 不能被判损坏：\(output)"
        )
    }

    /// @argfile 同样要用真实 JVM 验收：语法错会被当成未知选项报出来。
    func testRealJVMAcceptsArgfile() throws {
        try XCTSkipIf(TestToolchain.availableJDK() == nil, "系统没有可用 JDK")
        let plan = try plan(shorten: "ARGFILE", classpath: ["/tmp/a.jar"])
        defer { plan.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) } }
        guard let argfile = plan.arguments.first(where: { $0.hasPrefix("@") }) else {
            return XCTFail("缺少 @argfile")
        }

        let output = try runJava(arguments: [argfile, "com.example.DoesNotExist"])
        XCTAssertTrue(output.contains("com.example.DoesNotExist"), "类名应出现在报错里（argfile 已被接受），实际输出：\(output)")
        XCTAssertFalse(
            output.lowercased().contains("unrecognized") || output.contains("无法识别"),
            "argfile 语法不能被拒绝：\(output)"
        )
    }

    /// 用真实 java 跑一次给定参数，返回合并输出（不存在的主类 → 退出码 1 + 明确报错）。
    private func runJava(arguments: [String]) throws -> String {
        let java = TestToolchain.availableJDK().unsafelyUnwrapped.javaExecutable
        let process = Process()
        process.executableURL = java
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
