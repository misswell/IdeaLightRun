import Foundation

/// §15: Gradle 可执行文件定位。
///
/// 与 Maven 一样不能只查 PATH：从 Dock 启动的 GUI 看不到 Homebrew / SDKMAN 的
/// `/opt/homebrew/bin`、`~/.sdkman/candidates/gradle/current/bin`。项目自带
/// `gradlew` 永远排第一——wrapper 锁定了项目声明的 Gradle 版本。
public struct GradleLocator: Sendable {
    public enum Source: String, Codable, Sendable {
        case projectWrapper
        case gradleHomeEnv
        case path
        case knownLocation
        case wrapperDistribution

        var label: String {
            switch self {
            case .projectWrapper: return "项目 gradlew"
            case .gradleHomeEnv: return "GRADLE_HOME"
            case .path: return "PATH"
            case .knownLocation: return "常见安装位置"
            case .wrapperDistribution: return "Gradle Wrapper 发行版"
            }
        }
    }

    public struct Candidate: Equatable, Sendable {
        public let executable: URL
        public let source: Source

        public init(executable: URL, source: Source) {
            self.executable = executable
            self.source = source
        }
    }

    public let projectRoot: URL
    public let environment: [String: String]
    public let homeDirectory: URL
    public let knownLocations: [URL]

    public init(
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        knownLocations: [URL]? = nil
    ) {
        self.projectRoot = projectRoot
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.knownLocations = knownLocations
            ?? GradleLocator.defaultKnownLocations(homeDirectory: homeDirectory)
    }

    public static func defaultKnownLocations(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/gradle"),   // Apple Silicon Homebrew
            URL(fileURLWithPath: "/usr/local/bin/gradle"),      // Intel Homebrew
            URL(fileURLWithPath: "/opt/local/bin/gradle"),      // MacPorts
            homeDirectory.appendingPathComponent(".sdkman/candidates/gradle/current/bin/gradle"),
        ]
    }

    // MARK: - 查询

    public static func discover(projectRoot: URL) -> Candidate? {
        GradleLocator(projectRoot: projectRoot).firstUsable()
    }

    public func firstUsable() -> Candidate? {
        let fm = FileManager.default
        return attempted().first { fm.isExecutableFile(atPath: $0.executable.path) }
    }

    /// 所有尝试过的位置（含不可用的），供失败时给出可操作诊断。
    public func attempted() -> [Candidate] {
        var list: [Candidate] = []

        list.append(Candidate(
            executable: projectRoot.appendingPathComponent("gradlew"),
            source: .projectWrapper
        ))

        if let value = environment["GRADLE_HOME"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            list.append(Candidate(
                executable: URL(fileURLWithPath: value).appendingPathComponent("bin/gradle"),
                source: .gradleHomeEnv
            ))
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            guard !directory.isEmpty else { continue }
            list.append(Candidate(
                executable: URL(fileURLWithPath: String(directory)).appendingPathComponent("gradle"),
                source: .path
            ))
        }

        list.append(contentsOf: knownLocations.map {
            Candidate(executable: $0, source: .knownLocation)
        })

        // 只装了 wrapper 发行版、又没把 gradle 放进 PATH 的机器：
        // ~/.gradle/wrapper/dists/<name>/<hash>/gradle-<ver>/bin/gradle
        let wrapperDist = gradleUserHome()
            .appendingPathComponent("wrapper/dists", isDirectory: true)
        list.append(contentsOf: findExecutables(named: "gradle", under: wrapperDist, maxDepth: 4)
            .map { Candidate(executable: $0, source: .wrapperDistribution) })

        return dedupe(list)
    }

    public func failureDetail() -> String {
        var lines: [String] = ["找不到 Gradle。已尝试以下位置："]
        var order: [Source] = []
        var grouped: [Source: [String]] = [:]
        for candidate in attempted() {
            if grouped[candidate.source] == nil { order.append(candidate.source) }
            grouped[candidate.source, default: []].append(candidate.executable.path)
        }
        for source in order {
            let paths = grouped[source] ?? []
            if paths.count > 4 {
                let shown = paths.prefix(3).joined(separator: "、")
                lines.append("  · \(source.label)：\(shown) 等 \(paths.count) 项")
            } else {
                lines.append("  · \(source.label)：\(paths.joined(separator: "、"))")
            }
        }
        lines.append("解决办法：给项目加上 Gradle Wrapper（gradlew），或安装 Gradle（brew install gradle）后重试。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 内部

    private func gradleUserHome() -> URL {
        if let value = environment["GRADLE_USER_HOME"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".gradle", isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func findExecutables(named name: String, under directory: URL, maxDepth: Int) -> [URL] {
        guard maxDepth >= 0, isDirectory(directory) else { return [] }
        var found: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.lastPathComponent == name {
                found.append(entry)
            }
            for entry in entries where isDirectory(entry) {
                found.append(contentsOf: findExecutables(named: name, under: entry, maxDepth: maxDepth - 1))
            }
        }
        return found
    }

    private func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.executable.path).inserted }
    }
}
