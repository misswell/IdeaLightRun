import Foundation

public struct MavenModuleInfo: Equatable, Codable, Sendable {
    public var groupId: String?
    public var artifactId: String
    public var version: String?
    public var packaging: String
    public var directory: URL
    public var pomURL: URL

    public init(
        groupId: String?,
        artifactId: String,
        version: String?,
        packaging: String,
        directory: URL,
        pomURL: URL
    ) {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.packaging = packaging
        self.directory = directory
        self.pomURL = pomURL
    }
}

/// §80: 不重写 Maven 依赖解析，只读取 pom 结构用于模块映射。
/// 完整 reactor 图与 classpath 解析在 Milestone 2 实现。
public enum MavenPomReader {
    public static func read(
        pomURL: URL,
        inheritedGroupId: String?,
        inheritedVersion: String?
    ) -> (info: MavenModuleInfo, moduleNames: [String])? {
        let projectNodes = XMLSubtreeParser.parse(fileURL: pomURL, elementName: "project")
        guard let node = projectNodes.first else { return nil }

        let artifactId = node.firstChild("artifactId")?.text ?? ""
        guard !artifactId.isEmpty else { return nil }

        var groupId = node.firstChild("groupId")?.text
        var version = node.firstChild("version")?.text
        if groupId == nil || version == nil, let parent = node.firstChild("parent") {
            if groupId == nil { groupId = parent.firstChild("groupId")?.text }
            if version == nil { version = parent.firstChild("version")?.text }
        }
        if groupId == nil { groupId = inheritedGroupId }
        if version == nil { version = inheritedVersion }

        let packaging = node.firstChild("packaging")?.text ?? "jar"
        let moduleNames = (node.firstChild("modules")?.childrenNamed("module") ?? [])
            .compactMap { $0.text }
            .filter { !$0.isEmpty }

        let info = MavenModuleInfo(
            groupId: groupId,
            artifactId: artifactId,
            version: version,
            packaging: packaging,
            directory: pomURL.deletingLastPathComponent(),
            pomURL: pomURL
        )
        return (info, moduleNames)
    }

    /// §16: 递归建立 Maven reactor 模块列表。
    public static func collectReactor(rootPom: URL, maxDepth: Int = 8) -> [MavenModuleInfo] {
        var results: [MavenModuleInfo] = []

        func visit(_ pomURL: URL, groupId: String?, version: String?, depth: Int) {
            guard depth <= maxDepth,
                  let (info, moduleNames) = read(pomURL: pomURL, inheritedGroupId: groupId, inheritedVersion: version) else {
                return
            }
            results.append(info)
            let baseDirectory = pomURL.deletingLastPathComponent()
            for name in moduleNames {
                let childPom = baseDirectory
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("pom.xml")
                visit(childPom, groupId: info.groupId, version: info.version, depth: depth + 1)
            }
        }

        visit(rootPom, groupId: nil, version: nil, depth: 0)
        return results
    }
}
