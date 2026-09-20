import Foundation

/// §15: Maven 可执行文件定位。
///
/// 不能只查 PATH：从 Dock/Finder 启动的 GUI 拿到的 PATH 是
/// `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`，Homebrew 的 `/opt/homebrew/bin/mvn`
/// 与用户 shell 里装的 Maven 全部不可见，于是报"找不到 Maven"，而 IDEA 却能正常构建——
/// 因为 IDEA 用的是它自带的 Maven，不依赖 shell PATH。这里按同样的优先级枚举绝对路径。
public struct MavenLocator: Sendable {
    public enum Source: String, Codable, Sendable {
        case projectWrapper
        case mavenHomeEnv
        case path
        case ideBundled
        case knownLocation
        case wrapperDistribution

        var label: String {
            switch self {
            case .projectWrapper: return "项目 mvnw"
            case .mavenHomeEnv: return "MAVEN_HOME / M2_HOME"
            case .path: return "PATH"
            case .ideBundled: return "IDEA 自带 Maven"
            case .knownLocation: return "常见安装位置"
            case .wrapperDistribution: return "Maven Wrapper 发行版"
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
    public let applicationDirectories: [URL]
    /// 常见安装位置：从 Dock 启动时这些路径不在 PATH 里，必须逐个绝对路径探测。
    public let knownLocations: [URL]

    public init(
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL] = MavenLocator.defaultApplicationDirectories(),
        knownLocations: [URL] = MavenLocator.defaultKnownLocations(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    ) {
        self.projectRoot = projectRoot
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.applicationDirectories = applicationDirectories
        self.knownLocations = knownLocations
    }

    public static func defaultApplicationDirectories() -> [URL] {
        var dirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        // Toolbox 安装的 IDE 不在 /Applications 下
        dirs.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps", isDirectory: true)
        )
        return dirs
    }

    public static func defaultKnownLocations(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/mvn"),   // Apple Silicon Homebrew
            URL(fileURLWithPath: "/usr/local/bin/mvn"),      // Intel Homebrew
            URL(fileURLWithPath: "/opt/local/bin/mvn"),      // MacPorts
            homeDirectory.appendingPathComponent(".sdkman/candidates/maven/current/bin/mvn"),
        ]
    }

    // MARK: - 查询

    public static func discover(projectRoot: URL) -> Candidate? {
        MavenLocator(projectRoot: projectRoot).firstUsable()
    }

    public func firstUsable() -> Candidate? {
        let fm = FileManager.default
        return attempted().first { fm.isExecutableFile(atPath: $0.executable.path) }
    }

    /// 所有尝试过的位置（含不可用的），供失败时给出可操作的诊断而不是只说"没找到"。
    public func attempted() -> [Candidate] {
        var list: [Candidate] = []

        list.append(Candidate(
            executable: projectRoot.appendingPathComponent("mvnw"),
            source: .projectWrapper
        ))

        for key in ["MAVEN_HOME", "M2_HOME"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                list.append(Candidate(
                    executable: URL(fileURLWithPath: value).appendingPathComponent("bin/mvn"),
                    source: .mavenHomeEnv
                ))
            }
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            guard !directory.isEmpty else { continue }
            list.append(Candidate(
                executable: URL(fileURLWithPath: String(directory)).appendingPathComponent("mvn"),
                source: .path
            ))
        }

        list.append(contentsOf: ideBundled().map { Candidate(executable: $0, source: .ideBundled) })

        list.append(contentsOf: knownLocations.map {
            Candidate(executable: $0, source: .knownLocation)
        })

        let wrapperDist = homeDirectory
            .appendingPathComponent(".m2/wrapper/dists", isDirectory: true)
        list.append(contentsOf: findExecutables(named: "mvn", under: wrapperDist, maxDepth: 5)
            .map { Candidate(executable: $0, source: .wrapperDistribution) })

        return dedupe(list)
    }

    /// 找不到 Maven 时列出查过的位置：只说"没找到"用户无从下手。
    public func failureDetail() -> String {
        var lines: [String] = ["找不到 Maven。已尝试以下位置："]
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
        lines.append("解决办法：给项目加上 Maven Wrapper（mvnw），或安装 Maven / IDEA 后重试。")
        return lines.joined(separator: "\n")
    }

    /// IDEA / 其他 JetBrains IDE 的自带 Maven：
    /// `<App>.app/Contents/plugins/maven/lib/maven3/bin/mvn`
    private func ideBundled() -> [URL] {
        applicationDirectories.flatMap { directory -> [URL] in
            // /Applications 与 ~/Applications 直接按 app 名匹配；Toolbox 目录下 IDE 埋在版本层里。
            appBundles(in: directory, depth: 3)
                .map { $0.appendingPathComponent("Contents/plugins/maven/lib/maven3/bin/mvn") }
        }
    }

    private func appBundles(in directory: URL, depth: Int) -> [URL] {
        guard depth >= 0 else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var apps: [URL] = []
        var descent: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                apps.append(entry)
            } else if depth > 0, isDirectory(entry) {
                descent.append(entry)
            }
        }
        let ideaApps = apps.filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains("IDEA") }
        return ideaApps + descent.flatMap { appBundles(in: $0, depth: depth - 1) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// 有界深度地找可执行文件；只在已知的窄目录（wrapper 发行版）上使用。
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
