import CryptoKit
import Foundation

/// 一个模块的监听范围与编译目标。源码根只列真实存在的标准目录；
/// 共享模块被别的服务依赖时，改动它也会触发它自己的增量编译，
/// 而不是要求用户先手动 install。
public struct HotReloadModuleWatch: Sendable {
    public var module: ProjectModule
    public var target: BuildTarget
    public var codeRoots: [URL]
    public var resourceRoots: [URL]

    public init(module: ProjectModule, target: BuildTarget, codeRoots: [URL], resourceRoots: [URL]) {
        self.module = module
        self.target = target
        self.codeRoots = codeRoots
        self.resourceRoots = resourceRoots
    }

    public var allRoots: [URL] { codeRoots + resourceRoots }
}

public struct HotReloadFileState: Equatable, Sendable {
    public var path: String
    public var fingerprint: String
    public var size: Int
    public var modifiedAt: Date

    public init(path: String, fingerprint: String, size: Int, modifiedAt: Date) {
        self.path = path
        self.fingerprint = fingerprint
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct HotReloadWorkspaceSnapshot: Equatable, Sendable {
    public var sources: [String: HotReloadFileState]
    public var sourceResources: [String: HotReloadFileState]
    public var classes: [String: HotReloadFileState]
    public var outputResources: [String: HotReloadFileState]
    /// 绝对 class 文件路径 → JVM 二进制类名（`com.foo.Outer$Inner`）。
    public var classNames: [String: String]
    /// 绝对 class 文件路径 → 它所在的输出目录。多模块可能产出同名类，
    /// 只靠类名无法判断 JVM 实际加载的是哪一份。
    public var classOrigins: [String: String]
    public var capturedAt: Date
    public var truncated: Bool

    public init(
        sources: [String: HotReloadFileState] = [:],
        sourceResources: [String: HotReloadFileState] = [:],
        classes: [String: HotReloadFileState] = [:],
        outputResources: [String: HotReloadFileState] = [:],
        classNames: [String: String] = [:],
        classOrigins: [String: String] = [:],
        capturedAt: Date = Date(),
        truncated: Bool = false
    ) {
        self.sources = sources
        self.sourceResources = sourceResources
        self.classes = classes
        self.outputResources = outputResources
        self.classNames = classNames
        self.classOrigins = classOrigins
        self.capturedAt = capturedAt
        self.truncated = truncated
    }

    public var isEmpty: Bool {
        sources.isEmpty && sourceResources.isEmpty && classes.isEmpty && outputResources.isEmpty
    }
}

public struct HotReloadWorkspaceDiff: Equatable, Sendable {
    public var changedSources: [HotReloadFileState] = []
    public var removedSources: [String] = []
    public var changedSourceResources: [HotReloadFileState] = []
    public var removedSourceResources: [String] = []
    public var classChanges: [HotReloadClassChange] = []
    public var changedOutputResources: [HotReloadFileState] = []
    public var removedOutputResources: [String] = []

    public init() {}

    public var hasSourceChanges: Bool {
        !changedSources.isEmpty || !removedSources.isEmpty
    }

    public var hasSourceResourceChanges: Bool {
        !changedSourceResources.isEmpty || !removedSourceResources.isEmpty
    }

    public var hasOutputChanges: Bool {
        !classChanges.isEmpty || !changedOutputResources.isEmpty || !removedOutputResources.isEmpty
    }

    public var isEmpty: Bool {
        !hasSourceChanges && !hasSourceResourceChanges && !hasOutputChanges
    }

    /// 对外展示的资源变更（源资源 + 输出资源按项目相对路径去重）。
    public func resourceChanges(projectRoot: URL) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let rootPath = projectRoot.standardizedFileURL.path
        for file in changedSourceResources {
            let display = Self.displayPath(file.path, projectRoot: rootPath)
            if seen.insert(display).inserted { result.append(display) }
        }
        for file in changedOutputResources {
            let display = Self.displayPath(file.path, projectRoot: rootPath)
            if seen.insert(display).inserted { result.append(display) }
        }
        return result.sorted()
    }

    public func sourceChanges(projectRoot: URL) -> [String] {
        let rootPath = projectRoot.standardizedFileURL.path
        return (changedSources.map(\.path) + removedSources)
            .map { Self.displayPath($0, projectRoot: rootPath) }
            .sorted()
    }

    static func displayPath(_ path: String, projectRoot: String) -> String {
        guard path.hasPrefix(projectRoot + "/") else { return path }
        return String(path.dropFirst(projectRoot.count + 1))
    }
}

/// §HotReload: 监听范围 = 标准源码目录 + runtime classpath 中位于项目内的目录。
/// 只监听这两类路径，既覆盖保存源码，也覆盖 IDEA / 命令行等外部构建产物。
public struct HotReloadWorkspace: Sendable {
    public var projectRoot: URL
    public var primaryModule: ProjectModule
    public var primaryTarget: BuildTarget
    public var moduleWatches: [HotReloadModuleWatch]
    public var outputRoots: [URL]
    public var ignoredPaths: [String]
    /// 单次快照最多遍历的文件数，防止超大产物目录拖死主线程。
    public var maxFiles: Int

    public static let standardCodeSubdirectories = [
        "src/main/java",
        "src/main/kotlin",
        "src/main/groovy",
        "src/main/scala"
    ]
    public static let standardResourceSubdirectories = ["src/main/resources"]
    static let codeExtensions: Set<String> = ["java", "kt", "groovy", "scala"]
    static let maxContentHashSize = 4 * 1024 * 1024
    public static let defaultMaxFiles = 200_000
    static let maxModuleWatches = 500

    public init(
        projectRoot: URL,
        primaryModule: ProjectModule,
        primaryTarget: BuildTarget,
        moduleWatches: [HotReloadModuleWatch],
        outputRoots: [URL],
        ignoredPaths: [String] = [],
        maxFiles: Int = HotReloadWorkspace.defaultMaxFiles
    ) {
        self.projectRoot = projectRoot
        self.primaryModule = primaryModule
        self.primaryTarget = primaryTarget
        self.moduleWatches = moduleWatches
        self.outputRoots = outputRoots
        self.ignoredPaths = ignoredPaths
        self.maxFiles = maxFiles
    }

    // MARK: - 构建

    public static func make(
        projectRoot: URL,
        scan: ScanResult,
        primaryModule: ProjectModule,
        adapter: any BuildSystemAdapter,
        includeProvided: Bool,
        classpath: [String],
        configuration: HotReloadConfiguration
    ) -> HotReloadWorkspace {
        let root = projectRoot.standardizedFileURL
        let rootPath = root.path
        let ignored = normalizedIgnoredPaths(configuration.ignoredPaths, projectRoot: root)

        var modules: [ProjectModule] = [primaryModule]
        for module in scan.modules where !modules.contains(where: {
            $0.directory.standardizedFileURL == module.directory.standardizedFileURL
        }) {
            modules.append(module)
        }

        var watches: [HotReloadModuleWatch] = []
        var watchedRootPaths = Set<String>()
        for module in modules.prefix(maxModuleWatches) {
            let directory = module.directory.standardizedFileURL
            let codeRoots = standardCodeSubdirectories
                .map { directory.appendingPathComponent($0, isDirectory: true) }
                .filter { isDirectory($0) }
            let resourceRoots = standardResourceSubdirectories
                .map { directory.appendingPathComponent($0, isDirectory: true) }
                .filter { isDirectory($0) }
            guard !codeRoots.isEmpty || !resourceRoots.isEmpty else { continue }

            let roots = codeRoots + resourceRoots
            // 同一目录被 .iml 与 settings.gradle 重复发现时只保留一份，避免重复编译。
            let signature = roots.map(\.standardizedFileURL.path).sorted().joined(separator: "|")
            guard watchedRootPaths.insert(signature).inserted else { continue }

            let target = BuildTarget(
                module: module,
                variant: adapter.classpathVariant(for: module, includeProvided: includeProvided)
            )
            watches.append(HotReloadModuleWatch(
                module: module,
                target: target,
                codeRoots: codeRoots,
                resourceRoots: resourceRoots
            ))
        }

        // 单模块项目可能没有 .iml / settings 记录；主模块在项目根时已经覆盖，
        // 否则把项目根的 src/main/* 归到主模块，保证保存源码仍能触发编译。
        if root != primaryModule.directory.standardizedFileURL {
            let codeRoots = standardCodeSubdirectories
                .map { root.appendingPathComponent($0, isDirectory: true) }
                .filter { isDirectory($0) }
            let resourceRoots = standardResourceSubdirectories
                .map { root.appendingPathComponent($0, isDirectory: true) }
                .filter { isDirectory($0) }
            let covered = codeRoots.allSatisfy { candidate in
                watches.contains { watch in
                    watch.codeRoots.contains { $0.standardizedFileURL == candidate.standardizedFileURL }
                }
            }
            if (!codeRoots.isEmpty || !resourceRoots.isEmpty), !covered {
                let target = BuildTarget(
                    module: primaryModule,
                    variant: adapter.classpathVariant(for: primaryModule, includeProvided: includeProvided)
                )
                watches.append(HotReloadModuleWatch(
                    module: primaryModule,
                    target: target,
                    codeRoots: codeRoots,
                    resourceRoots: resourceRoots
                ))
            }
        }

        if watches.isEmpty {
            // 没有标准源码目录仍然允许启动（例如纯依赖聚合模块），
            // 但主模块必须在列表里，手动触发才能编译。
            let target = BuildTarget(
                module: primaryModule,
                variant: adapter.classpathVariant(for: primaryModule, includeProvided: includeProvided)
            )
            watches = [HotReloadModuleWatch(
                module: primaryModule,
                target: target,
                codeRoots: [],
                resourceRoots: []
            )]
        }

        var outputRoots: [URL] = []
        var seenOutput = Set<String>()
        for entry in classpath {
            let url = URL(fileURLWithPath: entry).standardizedFileURL
            guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if seenOutput.insert(url.path).inserted {
                outputRoots.append(url)
            }
        }

        return HotReloadWorkspace(
            projectRoot: root,
            primaryModule: primaryModule,
            primaryTarget: BuildTarget(
                module: primaryModule,
                variant: adapter.classpathVariant(for: primaryModule, includeProvided: includeProvided)
            ),
            moduleWatches: watches,
            outputRoots: outputRoots,
            ignoredPaths: ignored
        )
    }

    public static func normalizedIgnoredPaths(_ raw: [String], projectRoot: URL) -> [String] {
        let root = projectRoot.standardizedFileURL.path
        return raw.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let url = trimmed.hasPrefix("/")
                ? URL(fileURLWithPath: trimmed)
                : URL(fileURLWithPath: trimmed, relativeTo: projectRoot)
            let path = url.standardizedFileURL.path
            guard path == root || path.hasPrefix(root + "/") else { return nil }
            return path
        }
    }

    // MARK: - 查询

    public var watchedRoots: [URL] {
        moduleWatches.flatMap(\.allRoots) + outputRoots
    }

    /// 事件路径是否落在监听范围内。FSEvents 也会报父目录（新增文件时），
    /// 只要它是某个监听根目录的祖先就值得重新快照一次。
    public func isRelevantPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if isIgnored(standardized) { return false }
        for root in watchedRoots {
            let rootPath = root.standardizedFileURL.path
            if standardized == rootPath
                || standardized.hasPrefix(rootPath + "/")
                || rootPath.hasPrefix(standardized + "/") {
                return true
            }
        }
        return false
    }

    public func isIgnored(_ path: String) -> Bool {
        for ignored in ignoredPaths {
            if path == ignored || path.hasPrefix(ignored + "/") { return true }
        }
        return false
    }

    /// 变更源文件归属的模块：取最长匹配根，避免根项目把子模块源码抢走。
    public func moduleWatch(forSourcePath path: String) -> HotReloadModuleWatch? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var best: (HotReloadModuleWatch, Int)?
        for watch in moduleWatches {
            for root in watch.allRoots {
                let rootPath = root.standardizedFileURL.path
                guard standardized == rootPath || standardized.hasPrefix(rootPath + "/") else { continue }
                if best == nil || rootPath.count > best!.1 {
                    best = (watch, rootPath.count)
                }
            }
        }
        return best?.0
    }

    // MARK: - 快照

    /// - Parameter previous: 上一次快照。size + mtime 未变的文件直接复用指纹，
    ///   否则每个文件事件都要把整个 `target/classes` 重新 SHA-256 一遍。
    public func snapshot(reusing previous: HotReloadWorkspaceSnapshot? = nil) -> HotReloadWorkspaceSnapshot {
        let budget = SnapshotBudget(limit: maxFiles)
        var sources: [String: HotReloadFileState] = [:]
        var sourceResources: [String: HotReloadFileState] = [:]
        var classes: [String: HotReloadFileState] = [:]
        var outputResources: [String: HotReloadFileState] = [:]
        var classNames: [String: String] = [:]
        var classOrigins: [String: String] = [:]

        for watch in moduleWatches {
            for root in watch.codeRoots {
                collect(root: root, previous: previous?.sources, budget: budget) { url in
                    Self.codeExtensions.contains(url.pathExtension.lowercased())
                } into: { state, _ in
                    sources[state.path] = state
                }
            }
            for root in watch.resourceRoots {
                collect(root: root, previous: previous?.sourceResources, budget: budget) { _ in
                    true
                } into: { state, _ in
                    sourceResources[state.path] = state
                }
            }
        }

        for root in outputRoots {
            let rootPath = root.standardizedFileURL.path
            let oldFiles = previous.map { snapshot in
                // 类与资源共用一份旧指纹表，按路径查即可。
                snapshot.classes.merging(snapshot.outputResources) { first, _ in first }
            }
            collect(root: root, previous: oldFiles, budget: budget) { _ in
                true
            } into: { state, _ in
                if state.path.hasSuffix(".class") {
                    if let name = Self.className(
                        forClassFile: state.path,
                        outputRoot: rootPath
                    ) {
                        classes[state.path] = state
                        classNames[state.path] = name
                        classOrigins[state.path] = rootPath
                    }
                } else {
                    outputResources[state.path] = state
                }
            }
        }

        return HotReloadWorkspaceSnapshot(
            sources: sources,
            sourceResources: sourceResources,
            classes: classes,
            outputResources: outputResources,
            classNames: classNames,
            classOrigins: classOrigins,
            truncated: budget.truncated
        )
    }

    private func collect(
        root: URL,
        previous: [String: HotReloadFileState]?,
        budget: SnapshotBudget,
        include: (URL) -> Bool,
        into sink: (HotReloadFileState, URL) -> Void
    ) {
        guard budget.hasRemaining else {
            budget.markTruncated()
            return
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let url as URL in enumerator {
            guard budget.hasRemaining else {
                budget.markTruncated()
                return
            }
            let path = url.standardizedFileURL.path
            if isIgnored(path) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  include(url) else {
                continue
            }
            guard budget.consume() else { return }
            let size = values.fileSize ?? 0
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fingerprint: String
            if let old = previous?[path],
               old.size == size,
               abs(old.modifiedAt.timeIntervalSince1970 - modifiedAt.timeIntervalSince1970) < 0.000_001,
               old.modifiedAt != .distantPast,
               modifiedAt != .distantPast {
                fingerprint = old.fingerprint
            } else {
                fingerprint = Self.fingerprint(url: url, size: size, modifiedAt: modifiedAt)
            }
            sink(
                HotReloadFileState(
                    path: path,
                    fingerprint: fingerprint,
                    size: size,
                    modifiedAt: modifiedAt
                ),
                url
            )
        }
    }

    static func fingerprint(url: URL, size: Int, modifiedAt: Date) -> String {
        if size <= maxContentHashSize, let data = try? Data(contentsOf: url) {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return "meta:\(size):\(modifiedAt.timeIntervalSince1970)"
    }

    /// 输出根下的 `.class` → JVM 二进制名。`META-INF/versions` 的多版本类
    /// 与 `module-info` 不参与重定义（前者由运行时选版本，后者不可修改）。
    public static func className(forClassFile path: String, outputRoot: String) -> String? {
        let rootPath = URL(fileURLWithPath: outputRoot).standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(rootPath + "/") else { return nil }
        var relative = String(standardized.dropFirst(rootPath.count + 1))
        guard relative.hasSuffix(".class") else { return nil }
        guard !relative.hasPrefix("META-INF/"), !relative.hasPrefix("BOOT-INF/") else { return nil }
        relative.removeLast(".class".count)
        guard !relative.isEmpty else { return nil }
        let name = relative.replacingOccurrences(of: "/", with: ".")
        guard name != "module-info", !name.hasSuffix(".module-info") else { return nil }
        return name
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// 快照遍历预算。引用类型是为了让 collect 与调用方共享同一个计数，
/// 避免 inout 与闭包同时访问同一个变量。
private final class SnapshotBudget {
    private var remaining: Int
    private(set) var truncated = false

    init(limit: Int) {
        remaining = max(1, limit)
    }

    var hasRemaining: Bool { remaining > 0 }

    func consume() -> Bool {
        guard remaining > 0 else {
            truncated = true
            return false
        }
        remaining -= 1
        return true
    }

    func markTruncated() {
        truncated = true
    }
}

extension HotReloadWorkspaceSnapshot {
    /// 与上一次快照比较。新增/删除类单独标记，删除类不可被 JVM 卸载，
    /// 调用方必须按“需要重启”处理，不能假装成功。
    public func diff(from previous: HotReloadWorkspaceSnapshot) -> HotReloadWorkspaceDiff {
        var diff = HotReloadWorkspaceDiff()
        diff.changedSources = changedKeys(previous.sources, sources).map { sources[$0]! }
        diff.removedSources = Set(previous.sources.keys).subtracting(sources.keys).sorted()
        diff.changedSourceResources = changedKeys(previous.sourceResources, sourceResources)
            .map { sourceResources[$0]! }
        diff.removedSourceResources = Set(previous.sourceResources.keys)
            .subtracting(sourceResources.keys).sorted()
        diff.changedOutputResources = changedKeys(previous.outputResources, outputResources)
            .map { outputResources[$0]! }
        diff.removedOutputResources = Set(previous.outputResources.keys)
            .subtracting(outputResources.keys).sorted()

        // 同名类在不同模块/输出目录里是不同身份：不能按类名合并，
        // 否则 Agent 会拿错文件，或者另一份变更被静默吞掉。
        var changesByIdentity: [String: HotReloadClassChange] = [:]
        for path in changedKeys(previous.classes, classes) {
            guard let name = classNames[path] else { continue }
            let kind: HotReloadClassChangeKind = previous.classes[path] == nil ? .added : .modified
            let origin = classOrigins[path]
            changesByIdentity[Self.classIdentity(name: name, origin: origin)] = HotReloadClassChange(
                className: name,
                filePath: path,
                kind: kind,
                outputRoot: origin
            )
        }
        for path in Set(previous.classes.keys).subtracting(classes.keys).sorted() {
            guard let name = previous.classNames[path] else { continue }
            let origin = previous.classOrigins[path]
            changesByIdentity[Self.classIdentity(name: name, origin: origin)] = HotReloadClassChange(
                className: name,
                filePath: path,
                kind: .removed,
                outputRoot: origin
            )
        }
        diff.classChanges = changesByIdentity.values.sorted {
            if $0.className != $1.className { return $0.className < $1.className }
            return ($0.outputRoot ?? "") < ($1.outputRoot ?? "")
        }
        return diff
    }

    static func classIdentity(name: String, origin: String?) -> String {
        "\(origin ?? "")\u{0}\(name)"
    }

    private func changedKeys(
        _ previous: [String: HotReloadFileState],
        _ current: [String: HotReloadFileState]
    ) -> [String] {
        current.keys.filter { path in
            guard let old = previous[path] else { return true }
            return old.fingerprint != current[path]?.fingerprint
        }.sorted()
    }
}
