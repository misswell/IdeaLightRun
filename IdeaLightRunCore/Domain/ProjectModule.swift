import Foundation

public struct ProjectModule: Equatable, Hashable, Codable, Sendable, Identifiable {
    public var name: String
    public var directory: URL
    public var imlURL: URL?
    public var artifactId: String?
    public var gradlePath: String?

    public var id: String { "\(name)@\(directory.path)" }

    public init(
        name: String,
        directory: URL,
        imlURL: URL? = nil,
        artifactId: String? = nil,
        gradlePath: String? = nil
    ) {
        self.name = name
        self.directory = directory
        self.imlURL = imlURL
        self.artifactId = artifactId
        self.gradlePath = gradlePath
    }
}

public enum ModuleResolutionMethod: String, Codable, Sendable {
    case byName
    case byArtifactId
    case byGradlePath
    case byMainClassFallback
    case notResolved
}

public struct ModuleResolution: Equatable, Codable, Sendable {
    public var module: ProjectModule?
    public var method: ModuleResolutionMethod
    public var warnings: [ConfigurationWarning]

    public init(module: ProjectModule?, method: ModuleResolutionMethod, warnings: [ConfigurationWarning]) {
        self.module = module
        self.method = method
        self.warnings = warnings
    }
}
