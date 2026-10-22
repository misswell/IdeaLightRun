import Foundation

public enum GradleSettingsReader {
    public struct Info: Equatable, Codable, Sendable {
        public var rootProjectName: String?
        /// Gradle project path，如 ":app"、":library:util"。
        public var includedProjects: [String]
        /// `project(":app").projectDir = file("apps/server")` 这类自定义目录映射。
        /// 键是 Gradle project path，值是相对 settings 目录的路径（原样保留）。
        public var projectDirectories: [String: String]

        public init(
            rootProjectName: String?,
            includedProjects: [String],
            projectDirectories: [String: String] = [:]
        ) {
            self.rootProjectName = rootProjectName
            self.includedProjects = includedProjects
            self.projectDirectories = projectDirectories
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
        var projectDirectories: [String: String] = [:]
        let projectDirPattern = #/project\s*\(\s*['"]([^'"]+)['"]\s*\)\s*\.\s*projectDir\s*=\s*file\s*\(\s*['"]([^'"]+)['"]\s*\)/#
        for line in content.split(separator: "\n") {
            var workingLine = Substring(line)
            if let commentIndex = workingLine.firstIndex(where: { $0 == "#" }) {
                workingLine = workingLine[..<commentIndex]
            }
            if let commentIndex = workingLine.range(of: "//") {
                workingLine = workingLine[..<commentIndex.lowerBound]
            }

            if let match = workingLine.firstMatch(of: projectDirPattern) {
                projectDirectories[normalizedProjectPath(String(match.1))] = String(match.2)
            }

            guard workingLine.range(of: #"include\b"#, options: .regularExpression) != nil else { continue }

            for match in workingLine.matches(of: #/['"]([^'"]+)['"]/#) {
                var path = String(match.1)
                guard !path.isEmpty else { continue }
                if !path.hasPrefix(":") { path = ":" + path }
                includedProjects.append(path)
            }
        }

        return Info(
            rootProjectName: rootProjectName,
            includedProjects: includedProjects,
            projectDirectories: projectDirectories
        )
    }

    private static func normalizedProjectPath(_ raw: String) -> String {
        raw.hasPrefix(":") ? raw : ":" + raw
    }
}
