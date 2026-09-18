import Foundation

/// §13: IDEA module name → 实际 module directory。
/// 方式一 modules.xml → *.iml；方式二扫描 *.iml；
/// 方式三 Maven artifactId；方式四 Gradle project name/path；
/// 最后 fallback：根据 mainClass 在 src/main/java|kotlin 下定位并向上找 pom/build.gradle。
public enum ModuleResolver {
    public static func collectModules(projectRoot: URL) -> [ProjectModule] {
        var modules: [ProjectModule] = []
        var seenNames = Set<String>()

        func add(_ module: ProjectModule) {
            let key = module.name.lowercased()
            guard !seenNames.contains(key) else { return }
            seenNames.insert(key)
            modules.append(module)
        }

        // 方式一：.idea/modules.xml → *.iml → content root
        for imlURL in ideaIMLFiles(projectRoot: projectRoot) {
            if let module = moduleFromIML(imlURL) {
                add(module)
            }
        }

        // 方式二：扫描 *.iml，补齐 modules.xml 未覆盖的模块
        for imlURL in scanIMLFiles(projectRoot: projectRoot) {
            let name = imlURL.deletingPathExtension().lastPathComponent
            guard !seenNames.contains(name.lowercased()) else { continue }
            if let module = moduleFromIML(imlURL, fallbackName: name) {
                add(module)
            }
        }

        // 方式三：Maven artifactId → module directory
        let rootPom = projectRoot.appendingPathComponent("pom.xml")
        if FileManager.default.fileExists(atPath: rootPom.path) {
            for info in MavenPomReader.collectReactor(rootPom: rootPom) {
                guard !seenNames.contains(info.artifactId.lowercased()) else { continue }
                add(ProjectModule(
                    name: info.artifactId,
                    directory: info.directory,
                    artifactId: info.artifactId
                ))
            }
        }

        // 方式四：Gradle settings
        let gradle = BuildSystemDetector.detect(projectRoot: projectRoot).gradle
        if let settingsURL = gradle?.settingsURL {
            let info = GradleSettingsReader.read(settingsURL: settingsURL)
            if let rootName = info.rootProjectName {
                add(ProjectModule(name: rootName, directory: projectRoot, gradlePath: ":"))
            }
            for gradlePath in info.includedProjects {
                // Gradle project path 以 ":" 分隔，如 ":library:util"
                let components = gradlePath
                    .drop(while: { $0 == ":" })
                    .split(separator: ":")
                    .map(String.init)
                guard let name = components.last, !name.isEmpty else { continue }
                var directory = projectRoot
                for component in components {
                    directory = directory.appendingPathComponent(component, isDirectory: true)
                }
                add(ProjectModule(name: name, directory: directory, gradlePath: gradlePath))
            }
        }

        return modules
    }

    public static func resolveModule(
        named moduleName: String?,
        mainClass: String?,
        projectRoot: URL,
        knownModules: [ProjectModule]
    ) -> ModuleResolution {
        let trimmedName = moduleName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let name = trimmedName, !name.isEmpty {
            if let exact = knownModules.first(where: { $0.name == name }) {
                return ModuleResolution(module: exact, method: .byName, warnings: [])
            }
            if let caseInsensitive = knownModules.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return ModuleResolution(module: caseInsensitive, method: .byName, warnings: [])
            }

            if name.contains(":") {
                let lastComponent = name.split(separator: ":").last.map(String.init) ?? name
                if let match = knownModules.first(where: { $0.artifactId == lastComponent || $0.name == lastComponent }) {
                    return ModuleResolution(module: match, method: .byArtifactId, warnings: [])
                }
                if let match = knownModules.first(where: { module in
                    module.gradlePath == name || module.gradlePath?.hasSuffix(":" + lastComponent) == true
                }) {
                    return ModuleResolution(module: match, method: .byGradlePath, warnings: [])
                }
            }

            // IDEA 的 Gradle 模块名有时是 "root.sub" 形式
            if name.contains(".") {
                let lastComponent = name.split(separator: ".").last.map(String.init) ?? name
                if let match = knownModules.first(where: { $0.name == lastComponent || $0.artifactId == lastComponent }) {
                    return ModuleResolution(module: match, method: .byName, warnings: [])
                }
            }

            // 最后 fallback：根据 mainClass 定位
            if let mainClass, !mainClass.isEmpty,
               let directory = moduleDirectory(forMainClass: mainClass, projectRoot: projectRoot) {
                let module = ProjectModule(name: directory.lastPathComponent, directory: directory)
                return ModuleResolution(
                    module: module,
                    method: .byMainClassFallback,
                    warnings: [.moduleNotFound(name: name)]
                )
            }
            return ModuleResolution(module: nil, method: .notResolved, warnings: [.moduleNotFound(name: name)])
        }

        // 未指定 module：仍允许 mainClass fallback
        if let mainClass, !mainClass.isEmpty,
           let directory = moduleDirectory(forMainClass: mainClass, projectRoot: projectRoot) {
            let module = ProjectModule(name: directory.lastPathComponent, directory: directory)
            return ModuleResolution(module: module, method: .byMainClassFallback, warnings: [])
        }
        return ModuleResolution(module: nil, method: .notResolved, warnings: [.missingModule])
    }

    // MARK: - mainClass fallback（§13 方式五）

    public static func moduleDirectory(forMainClass mainClass: String, projectRoot: URL) -> URL? {
        let relativePath = mainClass.replacingOccurrences(of: ".", with: "/")
        for sourceRoot in findSourceRoots(projectRoot: projectRoot) {
            for ext in ["java", "kt"] {
                let candidate = sourceRoot
                    .appendingPathComponent(relativePath, isDirectory: false)
                    .appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return nearestBuildRoot(from: candidate.deletingLastPathComponent(), stopAt: projectRoot)
                }
            }
        }
        return nil
    }

    static func nearestBuildRoot(from start: URL, stopAt projectRoot: URL) -> URL? {
        var directory = start.standardizedFileURL
        let stop = projectRoot.standardizedFileURL
        while true {
            for buildFileName in ["pom.xml", "build.gradle", "build.gradle.kts"] {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(buildFileName).path) {
                    return directory
                }
            }
            if directory.path == stop.path || directory.path == "/" {
                return nil
            }
            directory = directory.deletingLastPathComponent()
        }
    }

    static func findSourceRoots(projectRoot: URL) -> [URL] {
        var results: [URL] = []
        let ignored: Set<String> = [".git", "target", "build", "out", "node_modules", ".gradle", ".idea"]

        func walk(_ directory: URL, depth: Int) {
            guard depth <= 6,
                  let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
                return
            }
            for entry in entries {
                guard entry.hasDirectoryPath, !ignored.contains(entry.lastPathComponent) else { continue }
                let path = entry.path
                if path.hasSuffix("/src/main/java") || path.hasSuffix("/src/main/kotlin") {
                    results.append(entry)
                    continue
                }
                walk(entry, depth: depth + 1)
            }
        }

        walk(projectRoot, depth: 0)
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - IDEA modules（§13 方式一/二）

    private static func ideaIMLFiles(projectRoot: URL) -> [URL] {
        let modulesXML = projectRoot.appendingPathComponent(".idea/modules.xml")
        let nodes = XMLSubtreeParser.parse(fileURL: modulesXML, elementName: "module")
        return nodes.compactMap { node -> URL? in
            if let fileurl = node.attribute("fileurl") {
                return resolveIdeaFileURL(fileurl, projectRoot: projectRoot, moduleDir: projectRoot)
            }
            if let filepath = node.attribute("filepath") {
                return resolveIdeaFileURL(filepath, projectRoot: projectRoot, moduleDir: projectRoot)
            }
            return nil
        }
    }

    private static func scanIMLFiles(projectRoot: URL) -> [URL] {
        var results: [URL] = []
        let ignored: Set<String> = [".git", "target", "build", "out", "node_modules", ".gradle"]

        func walk(_ directory: URL, depth: Int) {
            guard depth <= 4,
                  let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
                return
            }
            for entry in entries {
                guard !ignored.contains(entry.lastPathComponent) else { continue }
                if entry.hasDirectoryPath {
                    walk(entry, depth: depth + 1)
                } else if entry.pathExtension == "iml" {
                    results.append(entry)
                }
            }
        }

        walk(projectRoot, depth: 0)
        return results.sorted { $0.path < $1.path }
    }

    private static func moduleFromIML(_ imlURL: URL, fallbackName: String? = nil) -> ProjectModule? {
        let name = fallbackName ?? imlURL.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }

        var directory = imlURL.deletingLastPathComponent()
        let contents = XMLSubtreeParser.parse(fileURL: imlURL, elementName: "content")
        if let contentURL = contents.first?.attribute("url") {
            let imlDirectory = imlURL.deletingLastPathComponent()
            if let resolved = resolveIdeaFileURL(contentURL, projectRoot: imlDirectory, moduleDir: imlDirectory) {
                directory = resolved
            }
        }

        return ProjectModule(name: name, directory: directory, imlURL: imlURL)
    }

    /// 形如 "file://$PROJECT_DIR$/gateway.iml" → 实际 URL。宏展开后再做百分号解码。
    static func resolveIdeaFileURL(_ raw: String, projectRoot: URL, moduleDir: URL) -> URL? {
        var string = raw
        let hasFileScheme = string.hasPrefix("file://")
        if hasFileScheme {
            string = String(string.dropFirst("file://".count))
        }

        string = string
            .replacingOccurrences(of: "$MODULE_DIR$", with: moduleDir.path)
            .replacingOccurrences(of: "$PROJECT_DIR$", with: projectRoot.path)
            .replacingOccurrences(of: "$MODULE_WORKING_DIR$", with: moduleDir.path)

        if hasFileScheme || string.hasPrefix("/") {
            if !string.hasPrefix("/") {
                string = "/" + string
            }
            let decoded = string.removingPercentEncoding ?? string
            return URL(fileURLWithPath: decoded)
        }
        return URL(fileURLWithPath: string)
    }
}
