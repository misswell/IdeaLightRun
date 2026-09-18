import Foundation

public enum GradleSettingsReader {
    public struct Info: Equatable, Codable, Sendable {
        public var rootProjectName: String?
        /// Gradle project path，如 ":app"、":library:util"。
        public var includedProjects: [String]

        public init(rootProjectName: String?, includedProjects: [String]) {
            self.rootProjectName = rootProjectName
            self.includedProjects = includedProjects
        }
    }

    /// 轻量文本解析（settings.gradle / settings.gradle.kts），不做完整 Groovy/Kotlin DSL 求值。
    public static func read(settingsURL: URL) -> Info {
        guard let content = try? String(contentsOf: settingsURL, encoding: .utf8) else {
            return Info(rootProjectName: nil, includedProjects: [])
        }

        var rootProjectName: String?
        if let match = content.firstMatch(of: #/rootProject\.name\s*=\s*['"]([^'"]+)['"]/#) {
            rootProjectName = String(match.1)
        }

        var includedProjects: [String] = []
        for line in content.split(separator: "\n") {
            var workingLine = Substring(line)
            if let commentIndex = workingLine.firstIndex(where: { $0 == "#" }) {
                workingLine = workingLine[..<commentIndex]
            }
            if let commentIndex = workingLine.range(of: "//") {
                workingLine = workingLine[..<commentIndex.lowerBound]
            }
            guard workingLine.range(of: #"include\b"#, options: .regularExpression) != nil else { continue }

            for match in workingLine.matches(of: #/['"]([^'"]+)['"]/#) {
                var path = String(match.1)
                guard !path.isEmpty else { continue }
                if !path.hasPrefix(":") { path = ":" + path }
                includedProjects.append(path)
            }
        }

        return Info(rootProjectName: rootProjectName, includedProjects: includedProjects)
    }
}
