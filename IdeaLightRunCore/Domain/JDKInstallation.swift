import Foundation

public struct JDKInstallation: Equatable, Hashable, Codable, Sendable, Identifiable {
    public var home: URL
    public var majorVersion: Int?
    public var versionString: String?
    public var vendor: String?
    public var displayName: String?

    public var id: String { home.path }
    public var javaExecutable: URL { home.appendingPathComponent("bin/java") }

    public init(
        home: URL,
        majorVersion: Int? = nil,
        versionString: String? = nil,
        vendor: String? = nil,
        displayName: String? = nil
    ) {
        self.home = home
        self.majorVersion = majorVersion
        self.versionString = versionString
        self.vendor = vendor
        self.displayName = displayName
    }
}

public enum JDKResolutionOrigin: String, Codable, Sendable {
    case runConfigurationSpecified
    case projectSDK
    case javaHome
    case systemInstalled
    case notResolved
}

public struct JDKResolution: Equatable, Codable, Sendable {
    public var installation: JDKInstallation?
    public var origin: JDKResolutionOrigin
    public var requiredName: String?
    public var warnings: [ConfigurationWarning]

    public var isResolved: Bool { installation != nil }

    public init(
        installation: JDKInstallation?,
        origin: JDKResolutionOrigin,
        requiredName: String?,
        warnings: [ConfigurationWarning]
    ) {
        self.installation = installation
        self.origin = origin
        self.requiredName = requiredName
        self.warnings = warnings
    }
}
