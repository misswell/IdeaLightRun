import Foundation

/// JUnit 目标解析成构建系统可用的精确筛选。
///
/// Maven 用 `-pl module -am` 时上游模块也会跑 test 阶段；只给包/整个模块这类
/// 宽泛目标会让上游模块的测试一起执行。这里把包、目录、整模块展开成具体测试类，
/// 上游模块拿到的筛选匹配不到任何类（配合 `failIfNoSpecifiedTests=false`），
/// 真正执行的只有目标模块的测试。
public enum TestTargetResolver {
    public static let testSourceRoots = [
        "src/test/java",
        "src/test/kotlin",
        "src/test/groovy",
        "src/testFixtures/java",
        "src/testFixtures/kotlin",
        "src/testFixtures/groovy",
    ]

    /// 规范化筛选：`Class` 或 `Class#method`。仅精确目标可能是空数组以外的形式。
    public static func resolve(
        _ target: JUnitRunOptions.Target,
        moduleDirectory: URL,
        projectRoot: URL,
        environment: [String: String] = [:]
    ) throws -> [String] {
        switch target {
        case .all:
            let classes = discoverAll(in: moduleDirectory)
            guard !classes.isEmpty else {
                throw IdeaLightRunError.noMatchingTests(
                    detail: "模块 \(moduleDirectory.lastPathComponent) 的测试源码目录里没有发现测试类。"
                        + "已查找：\(testSourceRoots.joined(separator: "、"))。"
                )
            }
            return classes
        case .package(let name):
            let prefix = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else {
                throw IdeaLightRunError.noMatchingTests(detail: "测试包名为空。")
            }
            let classes = discoverAll(in: moduleDirectory)
                .filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
            guard !classes.isEmpty else {
                throw IdeaLightRunError.noMatchingTests(
                    detail: "模块 \(moduleDirectory.lastPathComponent) 里没有包 “\(prefix)” 下的测试类。"
                )
            }
            return classes
        case .directory(let raw):
            let directory = resolveDirectory(
                raw,
                moduleDirectory: moduleDirectory,
                projectRoot: projectRoot,
                environment: environment
            )
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw IdeaLightRunError.invalidConfiguration(
                    detail: "JUnit 配置的测试目录不存在：\(directory.path)（原始值：\(raw)）"
                )
            }
            let classes = discoverTestClasses(in: directory)
            guard !classes.isEmpty else {
                throw IdeaLightRunError.noMatchingTests(
                    detail: "测试目录 \(directory.path) 下没有发现测试类。"
                )
            }
            return classes
        case .className(let name):
            return [name.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .method(let className, let methodName):
            return ["\(className.trimmingCharacters(in: .whitespacesAndNewlines))#\(methodName.trimmingCharacters(in: .whitespacesAndNewlines))"]
        case .patterns(let patterns):
            return try expandPatterns(
                patterns,
                moduleDirectory: moduleDirectory
            )
        case .tags, .uniqueId:
            throw IdeaLightRunError.unsupportedConfiguration(
                detail: "JUnit 的标签 / Unique ID 测试目标暂不支持；请改用类、方法、包或模式。"
            )
        case .unsupported(let reason):
            throw IdeaLightRunError.unsupportedConfiguration(detail: "JUnit 测试目标无效：\(reason)")
        }
    }

    /// 模块内全部标准测试源码根下的测试类（去重、排序）。
    public static func discoverAll(in moduleDirectory: URL) -> [String] {
        var classes = Set<String>()
        for root in testSourceRoots {
            let directory = moduleDirectory.appendingPathComponent(root, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            classes.formUnion(discoverTestClasses(in: directory))
        }
        return classes.sorted()
    }

    /// 扫描目录下的 Java / Kotlin / Groovy 测试类，返回 FQCN。
    public static func discoverTestClasses(in directory: URL) -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var classes = Set<String>()
        for case let file as URL in enumerator {
            guard ["java", "kt", "groovy"].contains(file.pathExtension) else { continue }
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard isTestSource(content) else { continue }
            let package = packageName(in: content)
            for name in classNames(in: content) {
                classes.insert(package.isEmpty ? name : "\(package).\(name)")
            }
        }
        return classes.sorted()
    }

    private static func resolveDirectory(
        _ raw: String,
        moduleDirectory: URL,
        projectRoot: URL,
        environment: [String: String]
    ) -> URL {
        let resolution = MacroResolver(
            projectDir: projectRoot,
            moduleDir: moduleDirectory,
            environment: environment
        ).resolve(raw)
        return RunConfigurationResolver.fileURL(
            for: resolution.value,
            projectRoot: projectRoot
        )
    }

    private static func expandPatterns(
        _ patterns: [String],
        moduleDirectory: URL
    ) throws -> [String] {
        let discovered = discoverAll(in: moduleDirectory)
        var result: [String] = []
        for pattern in patterns {
            let parts = pattern.split(separator: "#", maxSplits: 1).map(String.init)
            let classPattern = parts[0]
            let method = parts.count > 1 ? parts[1] : nil
            guard classPattern.contains("*") || classPattern.contains("?") else {
                let normalized = method.map { "\(classPattern)#\($0)" } ?? classPattern
                if !result.contains(normalized) { result.append(normalized) }
                continue
            }
            let regex = try wildcardRegex(classPattern)
            let matches = discovered.filter { regex.firstMatch(
                in: $0,
                options: [],
                range: NSRange(location: 0, length: ($0 as NSString).length)
            ) != nil }
            for className in matches {
                let normalized = method.map { "\(className)#\($0)" } ?? className
                if !result.contains(normalized) { result.append(normalized) }
            }
        }
        guard !result.isEmpty else {
            throw IdeaLightRunError.noMatchingTests(
                detail: "JUnit 测试模式没有匹配到任何测试类：\(patterns.joined(separator: ", "))"
            )
        }
        return result
    }

    private static func wildcardRegex(_ pattern: String) throws -> NSRegularExpression {
        var escaped = NSRegularExpression.escapedPattern(for: pattern)
        escaped = escaped.replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return try NSRegularExpression(pattern: "^\(escaped)$")
    }

    private static func isTestSource(_ content: String) -> Bool {
        if content.contains("@Test")
            || content.contains("@ParameterizedTest")
            || content.contains("@RepeatedTest")
            || content.contains("@TestFactory")
            || content.contains("@TestTemplate") {
            return true
        }
        if content.contains("extends TestCase") || content.contains("extends Specification") {
            return true
        }
        return false
    }

    private static func packageName(in content: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?m)^\\s*package\\s+([A-Za-z_][A-Za-z0-9_.]*)") else {
            return ""
        }
        let ns = content as NSString
        guard let match = regex.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) else {
            return ""
        }
        return ns.substring(with: match.range(at: 1))
    }

    /// 只收顶层类：嵌套类缩进在源码里，FQCN 需要 `Outer$Inner`，
    /// 用简单类名会生成错误的筛选。
    private static func classNames(in content: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?m)^(?:@[A-Za-z_][A-Za-z0-9_.]*(?:\\([^)]*\\))?\\s*)*"
                + "(?:(?:public|protected|private|internal|open|final|abstract|data|sealed|static|strictfp)\\s+)*"
                + "class\\s+([A-Za-z_][A-Za-z0-9_]*)"
        ) else {
            return []
        }
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}
