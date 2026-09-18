import Foundation

public protocol JDKLocating: Sendable {
    func locateJDKs() -> [JDKInstallation]
}

/// §24: 通过 /usr/libexec/java_home -V 与 JAVA_HOME 枚举系统 JDK。
public struct SystemJDCLocator: JDKLocating {
    public init() {}

    public func locateJDKs() -> [JDKInstallation] {
        var jdks = Self.parseJavaHomeOutput(Self.runJavaHomeVOutput())

        if let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"], !javaHome.isEmpty {
            let url = URL(fileURLWithPath: javaHome)
            if !jdks.contains(where: { $0.home.path == url.path }) {
                jdks.append(JDKInstallation(
                    home: url,
                    majorVersion: Self.majorVersion(fromDirectory: url),
                    displayName: "JAVA_HOME"
                ))
            }
        }
        return jdks
    }

    /// `java_home -V` 把列表输出到 stderr 且退出码非 0，属正常行为。
    static func runJavaHomeVOutput() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        process.arguments = ["-V"]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func parseJavaHomeOutput(_ output: String) -> [JDKInstallation] {
        var jdks: [JDKInstallation] = []
        // 例：    1.8.0_462 (arm64) "Amazon" - "Amazon Corretto 8" /Users/x/.../Contents/Home
        let pattern = #"\s*(\d+(?:[._]\d+)*)\s+\(\w+\)\s+"([^"]*)"\s+-\s+"([^"]*)"\s+(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for line in output.split(separator: "\n") {
            let lineString = String(line)
            let ns = lineString as NSString
            for match in regex.matches(in: lineString, range: NSRange(location: 0, length: ns.length)) {
                let versionString = ns.substring(with: match.range(at: 1))
                let vendor = ns.substring(with: match.range(at: 2))
                let displayName = ns.substring(with: match.range(at: 3))
                let home = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                guard !home.isEmpty else { continue }
                // JavaAppletPlugin 等浏览器插件 JRE 不是可用 JDK，跳过。
                if home.contains("/Internet Plug-Ins/") { continue }
                jdks.append(JDKInstallation(
                    home: URL(fileURLWithPath: home),
                    majorVersion: majorVersion(fromVersionString: versionString),
                    versionString: versionString,
                    vendor: vendor,
                    displayName: displayName
                ))
            }
        }
        return jdks
    }

    public static func majorVersion(fromVersionString version: String) -> Int? {
        // "1.8.0_462" → 8；"17.0.2" → 17；"8" → 8
        guard let match = version.firstMatch(of: #/^(\d+)(?:\.(\d+))?/#) else { return nil }
        let first = Int(match.1)
        let second = match.2.map { Int($0) } ?? nil
        if first == 1, let second {
            return second
        }
        return first
    }

    public static func majorVersion(fromDirectory home: URL) -> Int? {
        // 优先读 release 文件中的 JAVA_VERSION
        if let content = try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8),
           let match = content.firstMatch(of: #/JAVA_VERSION="?(\d+(?:[._]\d+)+)"?/#) {
            return majorVersion(fromVersionString: String(match.1))
        }
        return nil
    }
}

/// §23: JDK 解析优先级 ①配置指定 ②IDEA project SDK ③JAVA_HOME ④系统已安装。
public struct JDKResolver: Sendable {
    public var locator: JDKLocating

    public init(locator: JDKLocating = SystemJDCLocator()) {
        self.locator = locator
    }

    public func resolve(
        configJDKName: String?,
        projectJDKName: String?,
        candidates: [JDKInstallation]? = nil,
        javaHomePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> JDKResolution {
        let installed = candidates ?? locator.locateJDKs()

        // ① Run Configuration 指定的 JRE
        if let name = Self.requiredName(configJDKName) {
            if let jdk = Self.match(name: name, in: installed) {
                return JDKResolution(installation: jdk, origin: .runConfigurationSpecified, requiredName: name, warnings: [])
            }
            return Self.unresolved(requiredName: name, detail: "运行配置要求 JDK “\(name)”，但系统中未找到 major version 匹配的安装。")
        }

        // ② IDEA project SDK
        if let name = Self.requiredName(projectJDKName) {
            if let jdk = Self.match(name: name, in: installed) {
                return JDKResolution(installation: jdk, origin: .projectSDK, requiredName: name, warnings: [])
            }
            return Self.unresolved(requiredName: name, detail: "IDEA 项目 SDK “\(name)” 无法匹配到已安装的 JDK。")
        }

        // ③ JAVA_HOME
        let javaHome = javaHomePath ?? environment["JAVA_HOME"]
        if let home = javaHome, !home.isEmpty {
            let url = URL(fileURLWithPath: home)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("bin/java").path) {
                let jdk = JDKInstallation(
                    home: url,
                    majorVersion: SystemJDCLocator.majorVersion(fromDirectory: url),
                    displayName: "JAVA_HOME"
                )
                return JDKResolution(installation: jdk, origin: .javaHome, requiredName: nil, warnings: [])
            }
        }

        // ④ 系统已安装 JDK：无明确要求时选最高 major version
        if let best = installed.max(by: { ($0.majorVersion ?? 0) < ($1.majorVersion ?? 0) }) {
            return JDKResolution(installation: best, origin: .systemInstalled, requiredName: nil, warnings: [])
        }

        return Self.unresolved(requiredName: nil, detail: "未通过 /usr/libexec/java_home 或 JAVA_HOME 找到任何可用 JDK。")
    }

    static func unresolved(requiredName: String?, detail: String) -> JDKResolution {
        JDKResolution(
            installation: nil,
            origin: .notResolved,
            requiredName: requiredName,
            warnings: [.custom(title: "无法匹配 JDK", detail: detail)]
        )
    }

    static func requiredName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// §24: 不要求名字完全一致，按 majorVersion 匹配：
    /// 1.8 / 8 / jdk8 / JDK 1.8 / Temurin-8 / Corretto-8 / Zulu-8 都应命中 JDK 8。
    public static func match(name: String, in jdks: [JDKInstallation]) -> JDKInstallation? {
        if let exact = jdks.first(where: {
            $0.displayName == name || $0.versionString == name || $0.home.lastPathComponent == name
        }) {
            return exact
        }
        guard let major = majorVersion(fromName: name) else { return nil }
        return jdks.first { $0.majorVersion == major }
    }

    public static func majorVersion(fromName name: String) -> Int? {
        // 提取首个版本序列："1.8" → 8；"8" → 8；"Temurin-8" → 8；"JDK 17" → 17
        guard let match = name.firstMatch(of: #/(\d+)(?:\.(\d+))?/#) else { return nil }
        let first = Int(match.1)
        let second = match.2.map { Int($0) } ?? nil
        if first == 1, let second {
            return second
        }
        return first
    }
}
