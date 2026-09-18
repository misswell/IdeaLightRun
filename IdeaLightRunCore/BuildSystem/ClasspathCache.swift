import CryptoKit
import Foundation

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
/// 位置：~/Library/Caches/IdeaLightRun/projects/<projectHash>/maven/<moduleHash>/classpath.json
/// 失效条件见 mavenFingerprint（§57）：pom / .mvn / wrapper / settings.xml / JDK。
public enum ClasspathCache {
    public static func cacheDirectory(projectRoot: URL, moduleName: String) -> URL {
        let projectHash = sha256(projectRoot.standardizedFileURL.path)
        let moduleHash = sha256(moduleName)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IdeaLightRun/projects/\(projectHash)/maven/\(moduleHash)", isDirectory: true)
    }

    static func cachedClasspathURL(projectRoot: URL, moduleName: String) -> URL {
        cacheDirectory(projectRoot: projectRoot, moduleName: moduleName)
            .appendingPathComponent("classpath.json")
    }

    static func mavenOutputFileURL(projectRoot: URL, moduleName: String) -> URL {
        cacheDirectory(projectRoot: projectRoot, moduleName: moduleName)
            .appendingPathComponent("classpath-maven.txt")
    }

    public static func load(projectRoot: URL, moduleName: String) -> CachedClasspath? {
        guard let data = try? Data(contentsOf: cachedClasspathURL(projectRoot: projectRoot, moduleName: moduleName)),
              let cached = try? JSONDecoder().decode(CachedClasspath.self, from: data) else {
            return nil
        }
        return cached
    }

    public static func store(_ cached: CachedClasspath, projectRoot: URL, moduleName: String) {
        let directory = cacheDirectory(projectRoot: projectRoot, moduleName: moduleName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: cachedClasspathURL(projectRoot: projectRoot, moduleName: moduleName), options: .atomic)
    }

    /// §69: Rebuild Classpath —— 删除当前 module 的 classpath 缓存。
    public static func clear(projectRoot: URL, moduleName: String) {
        try? FileManager.default.removeItem(at: cacheDirectory(projectRoot: projectRoot, moduleName: moduleName))
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
