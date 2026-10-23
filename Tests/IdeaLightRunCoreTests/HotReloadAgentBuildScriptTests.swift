import XCTest
@testable import IdeaLightRunCore

/// 构建脚本必须在 JDK 8（无 --release）和 JDK 9+（有 --release）上都能产出 agent jar。
/// 两个 JDK 都存在的机器才运行；缺一个就跳过，不伪造结果。
final class HotReloadAgentBuildScriptTests: XCTestCase {
    func testAgentBuildsWithJdk8AndModernJdk() throws {
        let homes = Self.javaHomes()
        guard let jdk8 = homes.first(where: { Self.majorVersion(of: $0) == 8 }) else {
            throw XCTSkip("未安装 JDK 8，跳过 JDK 8 构建脚本验证。")
        }
        guard let modern = homes.first(where: { (Self.majorVersion(of: $0) ?? 0) >= 9 }) else {
            throw XCTSkip("未安装 JDK 9+，跳过现代 JDK 构建脚本验证。")
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/build-hot-reload-agent.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))

        for (home, label) in [(jdk8, "JDK 8"), (modern, "JDK 9+")] {
            let jar = outputDir.appendingPathComponent("agent-\(label).jar")
            let output = try Self.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, jar.path],
                workingDirectory: repoRoot,
                environment: ["JAVA_HOME": home.path]
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: jar.path),
                "\(label) 构建失败：\(output)"
            )
            XCTAssertTrue(
                output.contains("Built"),
                "\(label) 构建没有成功产物：\(output)"
            )
        }
    }

    // MARK: - JDK 探测

    private static func javaHomes() -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["JAVA_HOME"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        for base in [
            "/Library/Java/JavaVirtualMachines",
            NSHomeDirectory() + "/Library/Java/JavaVirtualMachines"
        ] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for entry in entries.sorted() {
                candidates.append(
                    URL(fileURLWithPath: base)
                        .appendingPathComponent(entry)
                        .appendingPathComponent("Contents/Home")
                )
            }
        }
        var seen = Set<String>()
        return candidates.filter { home in
            guard FileManager.default.isExecutableFile(
                atPath: home.appendingPathComponent("bin/javac").path
            ) else {
                return false
            }
            return seen.insert(home.resolvingSymlinksInPath().path).inserted
        }
    }

    private static func majorVersion(of home: URL) -> Int? {
        guard let output = try? run(
            executable: home.appendingPathComponent("bin/javac"),
            arguments: ["-version"],
            workingDirectory: home,
            environment: [:]
        ) else {
            return nil
        }
        // 输出形如 "javac 1.8.0_402" 或 "javac 17.0.2"。
        guard let token = output.split(whereSeparator: { $0.isWhitespace }).last else {
            return nil
        }
        let text = String(token)
        if text.hasPrefix("1.") {
            return Int(text.dropFirst(2).prefix(while: \.isNumber))
        }
        return Int(text.prefix(while: \.isNumber))
    }

    @discardableResult
    private static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        process.environment = merged
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "HotReloadAgentBuildScriptTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        return output
    }
}
