import CryptoKit
import Foundation

/// §6.1: classpath 的缓存身份。同一 module 在不同配置下可以是不同 classpath
/// （includeProvided  true/false），构建系统也一样会改变解析方式；
/// 三者不同时缓存必须分开，否则配置 A、B 会互相污染。
public struct ClasspathVariant: Hashable, Codable, Sendable {
    public var moduleIdentifier: String
    public var buildSystem: String
    public var includeProvided: Bool

    public init(moduleIdentifier: String, buildSystem: String, includeProvided: Bool) {
        self.moduleIdentifier = moduleIdentifier
        self.buildSystem = buildSystem
        self.includeProvided = includeProvided
    }

    public static func maven(module: String, includeProvided: Bool) -> ClasspathVariant {
        ClasspathVariant(moduleIdentifier: module, buildSystem: "maven", includeProvided: includeProvided)
    }

    /// 参与哈希的完整身份，逐项成行避免拼接歧义。
    var cacheKey: String {
        "module=\(moduleIdentifier)\nbuildSystem=\(buildSystem)\nincludeProvided=\(includeProvided)"
    }
}

public struct CachedClasspath: Codable, Sendable, Equatable {
    public var module: String
    public var entries: [String]
    public var fingerprint: String
    public var resolvedAt: Date

    public init(module: String, entries: [String], fingerprint: String, resolvedAt: Date) {
        self.module = module
        self.entries = entries
        self.fingerprint = fingerprint
        self.resolvedAt = resolvedAt
    }
}

/// §19: classpath 缓存。
/// 位置：~/Library/Caches/IdeaLightRun/projects/<projectHash>/<buildSystem>/<variantHash>/classpath.json
/// 失效条件见 mavenFingerprint（§57）：pom / .mvn / wrapper / settings.xml / JDK。
public enum ClasspathCache {
    public static func cacheDirectory(projectRoot: URL, variant: ClasspathVariant) -> URL {
        let projectHash = sha256(projectRoot.standardizedFileURL.path)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "IdeaLightRun/projects/\(projectHash)/\(variant.buildSystem)/\(sha256(variant.cacheKey))",
                isDirectory: true
            )
    }

    static func cachedClasspathURL(projectRoot: URL, variant: ClasspathVariant) -> URL {
        cacheDirectory(projectRoot: projectRoot, variant: variant)
            .appendingPathComponent("classpath.json")
    }

    public static func mavenOutputFileURL(
        projectRoot: URL,
        variant: ClasspathVariant,
        scope: MavenClasspathScope
    ) -> URL {
        cacheDirectory(projectRoot: projectRoot, variant: variant)
            .appendingPathComponent("classpath-maven-\(scope.rawValue).txt")
    }

    public static func load(projectRoot: URL, variant: ClasspathVariant) -> CachedClasspath? {
        guard let data = try? Data(contentsOf: cachedClasspathURL(projectRoot: projectRoot, variant: variant)),
              let cached = try? JSONDecoder().decode(CachedClasspath.self, from: data) else {
            return nil
        }
        return cached
    }

    public static func store(_ cached: CachedClasspath, projectRoot: URL, variant: ClasspathVariant) {
        let directory = cacheDirectory(projectRoot: projectRoot, variant: variant)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: cachedClasspathURL(projectRoot: projectRoot, variant: variant), options: .atomic)
    }

    /// §69: Rebuild Classpath —— 删除该 module 在两种 provided 取值下的 classpath 缓存。
    public static func clear(projectRoot: URL, variant: ClasspathVariant) {
        try? FileManager.default.removeItem(at: cacheDirectory(projectRoot: projectRoot, variant: variant))
    }

    public static func clear(projectRoot: URL, moduleName: String, buildSystem: String = "maven") {
        for includeProvided in [false, true] {
            clear(projectRoot: projectRoot, variant: ClasspathVariant(
                moduleIdentifier: moduleName, buildSystem: buildSystem, includeProvided: includeProvided
            ))
        }
    }

    public static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// §57: Maven fingerprint = 所有 reactor pom 内容 + .mvn 配置 + wrapper properties
    /// + ~/.m2/settings.xml 元数据 + JDK major。
    public static func mavenFingerprint(projectRoot: URL, reactorPoms: [URL], jdkMajor: Int?) -> String {
        var hasher = SHA256()
        func update(_ string: String) {
            hasher.update(data: Data(string.utf8))
        }

        for pom in reactorPoms.sorted(by: { $0.path < $1.path }) {
            update("pom:\(pom.path)\n")
            if let content = try? Data(contentsOf: pom) {
                hasher.update(data: content)
            }
        }

        let mvnDirectory = projectRoot.appendingPathComponent(".mvn")
        if let entries = try? FileManager.default.contentsOfDirectory(at: mvnDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
            for entry in entries where ["maven.config", "jvm.config", "extensions.xml"].contains(entry.lastPathComponent) {
                update("mvn:\(entry.lastPathComponent)\n")
                if let content = try? Data(contentsOf: entry) {
                    hasher.update(data: content)
                }
            }
        }
        let wrapperProperties = projectRoot.appendingPathComponent(".mvn/wrapper/maven-wrapper.properties")
        if let content = try? String(contentsOf: wrapperProperties, encoding: .utf8) {
            update("wrapper:\(content)")
        }

        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".m2/settings.xml")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: settings.path) {
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let size = attributes[.size] as? Int ?? 0
            update("settings:\(modified.timeIntervalSince1970)|\(size)\n")
        }

        if let major = jdkMajor {
            update("jdk:\(major)\n")
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
