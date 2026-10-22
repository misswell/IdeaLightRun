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

    /// `module` 用 Gradle project path（":app"），不用显示名：同名子项目在
    /// 不同路径下是不同模块，用名字会让它们的缓存互相覆盖。
    public static func gradle(module: String, includeProvided: Bool) -> ClasspathVariant {
        ClasspathVariant(moduleIdentifier: module, buildSystem: "gradle", includeProvided: includeProvided)
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

    public static func gradleOutputFileURL(projectRoot: URL, variant: ClasspathVariant) -> URL {
        cacheDirectory(projectRoot: projectRoot, variant: variant)
            .appendingPathComponent("classpath-gradle.txt")
    }

    public static func gradleInitScriptURL(projectRoot: URL, variant: ClasspathVariant) -> URL {
        cacheDirectory(projectRoot: projectRoot, variant: variant)
            .appendingPathComponent("idealauncher-init.gradle")
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

    // MARK: - §P0-7 缓存可用性校验

    /// 缓存可用性：fingerprint 匹配之外，条目还必须真实存在。
    /// `clean` 只删 `target/`、不动 pom——fingerprint 不变；只查 fingerprint 会
    /// 命中指向已删产物的缓存，启动直接 ClassNotFoundException。
    public enum CacheValidity: Equatable, Sendable {
        case usable
        /// pom / .mvn / wrapper / settings.xml / JDK 变化。
        case stale
        /// 部分或全部条目在磁盘上已不存在（clean、手删 target/ 等）。
        case entriesMissing([String])
        /// 缓存内容为空或损坏。
        case empty
    }

    /// fingerprint 匹配 + 每个条目在磁盘上真实存在才算命中（正确性优先于缓存，
    /// §24 约束 6）；否则视为 miss，由调用方重新解析并回写缓存（自修复）。
    public static func validate(_ cached: CachedClasspath, fingerprint: String) -> CacheValidity {
        guard !cached.entries.isEmpty else { return .empty }
        guard cached.fingerprint == fingerprint else { return .stale }
        let missing = cached.entries.filter { !FileManager.default.fileExists(atPath: $0) }
        return missing.isEmpty ? .usable : .entriesMissing(missing)
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

    /// §57: Gradle fingerprint = settings / 各项目构建脚本 / version catalog /
    /// wrapper properties / 根 gradle.properties / GRADLE_USER_HOME 的全局配置 + JDK major。
    /// 依赖版本、插件与 source set 布局都藏在这些文件里，任何一处变化都必须重新解析。
    public static func gradleFingerprint(
        projectRoot: URL,
        buildFiles: [URL],
        jdkMajor: Int?,
        gradleUserHome: URL
    ) -> String {
        var hasher = SHA256()
        func update(_ string: String) {
            hasher.update(data: Data(string.utf8))
        }

        // 生成 init script 的语义变化时必须让旧缓存失效。
        update("engine:gradle-classpath-v1\n")

        for file in buildFiles.sorted(by: { $0.path < $1.path }) {
            update("file:\(file.path)\n")
            if let content = try? Data(contentsOf: file) {
                hasher.update(data: content)
            }
        }

        // 全局配置与 Maven 的 settings.xml 同理：仓库、代理、镜像都会改变解析结果。
        for name in ["gradle.properties", "init.gradle", "init.gradle.kts"] {
            let url = gradleUserHome.appendingPathComponent(name)
            guard let content = try? Data(contentsOf: url) else { continue }
            update("user:\(name)\n")
            hasher.update(data: content)
        }
        let initDirectory = gradleUserHome.appendingPathComponent("init.d", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: initDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard let content = try? Data(contentsOf: entry) else { continue }
                update("user-init:\(entry.lastPathComponent)\n")
                hasher.update(data: content)
            }
        }

        let wrapperProperties = projectRoot.appendingPathComponent("gradle/wrapper/gradle-wrapper.properties")
        if let content = try? Data(contentsOf: wrapperProperties) {
            update("wrapper:\n")
            hasher.update(data: content)
        }

        if let major = jdkMajor {
            update("jdk:\(major)\n")
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
