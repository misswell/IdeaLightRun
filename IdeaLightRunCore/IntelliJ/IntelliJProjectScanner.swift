import Foundation

public struct ScanOptions: Sendable {
    /// §6: 递归 *.run.xml 最大深度 4。
    public var maxDepth: Int
    public var ignoredDirectoryNames: Set<String>

    public init(
        maxDepth: Int = 4,
        ignoredDirectoryNames: Set<String> = [".git", "target", "build", "out", "node_modules", ".gradle"]
    ) {
        self.maxDepth = maxDepth
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }
}

public struct ScanResult: Equatable, Codable, Sendable {
    public var projectRoot: URL
    public var configurations: [RunConfiguration]
    public var ignoredDuplicateCount: Int
    public var buildSystem: BuildSystemDetection
    public var projectJDKName: String?
    public var modules: [ProjectModule]

    public init(
        projectRoot: URL,
        configurations: [RunConfiguration],
        ignoredDuplicateCount: Int,
        buildSystem: BuildSystemDetection,
        projectJDKName: String?,
        modules: [ProjectModule]
    ) {
        self.projectRoot = projectRoot
        self.configurations = configurations
        self.ignoredDuplicateCount = ignoredDuplicateCount
        self.buildSystem = buildSystem
        self.projectJDKName = projectJDKName
        self.modules = modules
    }
}

/// §5/§6: 项目扫描入口。扫描顺序与去重优先级见 §7。
public struct IntelliJProjectScanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = .init()) {
        self.options = options
    }

    public func scan(projectRoot: URL) throws -> ScanResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IdeaLightRunError.projectNotFound(path: projectRoot.path)
        }

        var found: [RunConfiguration] = []
        let fm = FileManager.default

        // 优先级 1：.run/*.run.xml
        let dotRunDir = projectRoot.appendingPathComponent(".run", isDirectory: true)
        for file in listXMLFiles(in: dotRunDir, suffix: "run.xml") {
            found.append(contentsOf: (try? ProjectRunConfigurationParser.parse(fileURL: file, kind: .dotRun)) ?? [])
        }

        // 优先级 2：project/**/*.run.xml（深度 ≤ maxDepth）
        for file in recursiveRunXMLFiles(in: projectRoot) {
            found.append(contentsOf: (try? ProjectRunConfigurationParser.parse(fileURL: file, kind: .projectRunXML)) ?? [])
        }

        // 优先级 3：.idea/runConfigurations/*.xml
        let runConfigurationsDir = projectRoot.appendingPathComponent(".idea/runConfigurations", isDirectory: true)
        for file in listXMLFiles(in: runConfigurationsDir, suffix: "xml") {
            found.append(contentsOf: (try? ProjectRunConfigurationParser.parse(fileURL: file, kind: .ideaRunConfigurations)) ?? [])
        }

        // 优先级 4：.idea/workspace.xml
        let workspaceFile = projectRoot.appendingPathComponent(".idea/workspace.xml")
        if fm.fileExists(atPath: workspaceFile.path) {
            found.append(contentsOf: (try? WorkspaceRunConfigurationParser.parse(fileURL: workspaceFile)) ?? [])
        }

        // §7: 唯一键 type + name，按来源优先级去重。
        var best: [String: RunConfiguration] = [:]
        var duplicateCount = 0
        for config in found {
            if let existing = best[config.uniqueKey] {
                duplicateCount += 1
                if prefer(config, over: existing) {
                    best[config.uniqueKey] = config
                }
            } else {
                best[config.uniqueKey] = config
            }
        }

        let configurations = best.values.sorted { lhs, rhs in
            if lhs.type.sortRank != rhs.type.sortRank {
                return lhs.type.sortRank < rhs.type.sortRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return ScanResult(
            projectRoot: projectRoot,
            configurations: configurations,
            ignoredDuplicateCount: duplicateCount,
            buildSystem: BuildSystemDetector.detect(projectRoot: projectRoot),
            projectJDKName: IntelliJSDKReader.readProjectSDK(projectRoot: projectRoot)?.name,
            modules: ModuleResolver.collectModules(projectRoot: projectRoot)
        )
    }

    private func prefer(_ a: RunConfiguration, over b: RunConfiguration) -> Bool {
        if a.source.kind != b.source.kind {
            return a.source.kind.rawValue < b.source.kind.rawValue
        }
        let aModified = a.source.modifiedAt ?? .distantPast
        let bModified = b.source.modifiedAt ?? .distantPast
        return aModified > bModified
    }

    private func listXMLFiles(in directory: URL, suffix: String) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }
        return entries
            .filter { !$0.hasDirectoryPath && $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.path < $1.path }
    }

    private func recursiveRunXMLFiles(in root: URL) -> [URL] {
        var results: [URL] = []
        let dotRunDir = root.appendingPathComponent(".run", isDirectory: true)

        func walk(_ directory: URL, depth: Int) {
            guard depth <= options.maxDepth,
                  let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
                return
            }
            for entry in entries {
                if options.ignoredDirectoryNames.contains(entry.lastPathComponent) { continue }
                if entry.standardizedFileURL == dotRunDir.standardizedFileURL { continue }
                if entry.hasDirectoryPath {
                    walk(entry, depth: depth + 1)
                } else if entry.lastPathComponent.hasSuffix(".run.xml") {
                    results.append(entry)
                }
            }
        }

        walk(root, depth: 0)
        return results.sorted { $0.path < $1.path }
    }
}
