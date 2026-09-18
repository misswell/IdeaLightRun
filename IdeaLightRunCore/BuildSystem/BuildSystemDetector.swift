import Foundation

public struct MavenDetection: Equatable, Codable, Sendable {
    public var pomURL: URL
    /// §15: 项目自带 Wrapper 优先，必须单独记录。
    public var wrapperURL: URL?

    public init(pomURL: URL, wrapperURL: URL?) {
        self.pomURL = pomURL
        self.wrapperURL = wrapperURL
    }
}

public struct GradleDetection: Equatable, Codable, Sendable {
    public var settingsURL: URL?
    public var buildFileURL: URL
    public var wrapperURL: URL?
    public var usesKotlinDSL: Bool

    public init(settingsURL: URL?, buildFileURL: URL, wrapperURL: URL?, usesKotlinDSL: Bool) {
        self.settingsURL = settingsURL
        self.buildFileURL = buildFileURL
        self.wrapperURL = wrapperURL
        self.usesKotlinDSL = usesKotlinDSL
    }
}

public struct BuildSystemDetection: Equatable, Codable, Sendable {
    public var maven: MavenDetection?
    public var gradle: GradleDetection?

    public var isEmpty: Bool { maven == nil && gradle == nil }

    public init(maven: MavenDetection? = nil, gradle: GradleDetection? = nil) {
        self.maven = maven
        self.gradle = gradle
    }
}

public enum BuildSystemDetector {
    public static func detect(projectRoot: URL) -> BuildSystemDetection {
        let fm = FileManager.default
        var detection = BuildSystemDetection()

        let pom = projectRoot.appendingPathComponent("pom.xml")
        if fm.fileExists(atPath: pom.path) {
            let wrapper = projectRoot.appendingPathComponent("mvnw")
            detection.maven = MavenDetection(
                pomURL: pom,
                wrapperURL: fm.fileExists(atPath: wrapper.path) ? wrapper : nil
            )
        }

        let kotlinSettings = projectRoot.appendingPathComponent("settings.gradle.kts")
        let groovySettings = projectRoot.appendingPathComponent("settings.gradle")
        let kotlinBuild = projectRoot.appendingPathComponent("build.gradle.kts")
        let groovyBuild = projectRoot.appendingPathComponent("build.gradle")
        let gradlew = projectRoot.appendingPathComponent("gradlew")

        let hasGroovySettings = fm.fileExists(atPath: groovySettings.path)
        let hasKotlinSettings = fm.fileExists(atPath: kotlinSettings.path)
        let usesKotlin = hasKotlinSettings || fm.fileExists(atPath: kotlinBuild.path)
        let hasSettings = hasGroovySettings || hasKotlinSettings
        let hasBuild = fm.fileExists(atPath: groovyBuild.path) || fm.fileExists(atPath: kotlinBuild.path)

        if hasSettings || hasBuild {
            let buildFile = fm.fileExists(atPath: kotlinBuild.path) ? kotlinBuild : groovyBuild
            let settings: URL? = hasKotlinSettings ? kotlinSettings : (hasGroovySettings ? groovySettings : nil)
            detection.gradle = GradleDetection(
                settingsURL: settings,
                buildFileURL: buildFile,
                wrapperURL: fm.fileExists(atPath: gradlew.path) ? gradlew : nil,
                usesKotlinDSL: usesKotlin
            )
        }

        return detection
    }

    /// §48: 项目根目录至少要有 .idea / pom.xml / build.gradle / build.gradle.kts 之一。
    public static func isValidProjectRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent(".idea").path) { return true }
        if fm.fileExists(atPath: url.appendingPathComponent("pom.xml").path) { return true }
        if fm.fileExists(atPath: url.appendingPathComponent("build.gradle").path) { return true }
        if fm.fileExists(atPath: url.appendingPathComponent("build.gradle.kts").path) { return true }
        return false
    }
}
