import Foundation

/// §18: classpath 归一化——reactor 内部依赖转 target/classes，
/// 不长期依赖 common-1.0-SNAPSHOT.jar，保证重启即用最新编译代码（§92/§93）。
public enum MavenClasspathResolver {
    /// 解析符号链接（/tmp → /private/tmp 等），保证路径比较一致。
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
    }

    public static func normalize(
        entries: [String],
        reactor: [MavenModuleInfo],
        targetModuleDirectory: URL
    ) -> [String] {
        var result: [String] = []
        func push(_ path: String) {
            let canonical = canonicalPath(path)
            if !result.contains(canonical) {
                result.append(canonical)
            }
        }

        let targetClasses = targetModuleDirectory.appendingPathComponent("target/classes").path
        if FileManager.default.fileExists(atPath: targetClasses) {
            push(targetClasses)
        }

        for entry in entries {
            let basename = (entry as NSString).lastPathComponent
            if let matched = reactorModule(forJarBasename: basename, in: reactor) {
                let classesDirectory = matched.directory.appendingPathComponent("target/classes").path
                if FileManager.default.fileExists(atPath: classesDirectory) {
                    push(classesDirectory)
                    continue
                }
            }
            push(entry)
        }
        return result
    }

    private static func reactorModule(forJarBasename basename: String, in reactor: [MavenModuleInfo]) -> MavenModuleInfo? {
        guard basename.hasSuffix(".jar") else { return nil }
        for info in reactor {
            // 版本已知 → 精确匹配；未知 → 前缀匹配（保守）
            if let version = info.version {
                if basename == "\(info.artifactId)-\(version).jar" {
                    return info
                }
            } else if basename.hasPrefix("\(info.artifactId)-") {
                return info
            }
        }
        return nil
    }
}
