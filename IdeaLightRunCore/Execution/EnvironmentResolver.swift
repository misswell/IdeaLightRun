import Foundation

/// §4: 环境变量装配。IDEA 的语义在这里落地：父进程环境是否继承、`.env` 文件按顺序叠加、
/// Run Configuration 的显式变量优先级最高。
public enum EnvironmentResolver {
    /// §4.1: PASS_PARENT_ENVS=false 时不继承完整父进程环境，只留启动所需最小集合。
    /// 构建工具的 JAVA_HOME 由 `MavenBuildService.buildEnvironment` 单独注入，不走这里。
    public static let minimalParentEnvironmentKeys: [String] = ["HOME", "TMPDIR"]

    public struct Resolved: Sendable, Equatable {
        public var values: [String: String]
        public var warnings: [ConfigurationWarning]
        /// 只记录路径：文件内容与键值不得进入日志（§17）。
        public var loadedFiles: [String]

        public init(
            values: [String: String] = [:],
            warnings: [ConfigurationWarning] = [],
            loadedFiles: [String] = []
        ) {
            self.values = values
            self.warnings = warnings
            self.loadedFiles = loadedFiles
        }
    }

    public static func resolve(
        passParentEnvironment: Bool,
        environmentFiles: [String],
        environmentVariables: [String: String],
        macros: MacroResolver,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) throws -> Resolved {
        var resolved = Resolved()
        if passParentEnvironment {
            resolved.values = parentEnvironment
        } else {
            for key in minimalParentEnvironmentKeys {
                if let value = parentEnvironment[key] { resolved.values[key] = value }
            }
        }

        for rawPath in environmentFiles {
            let pathResolution = macros.resolve(rawPath)
            resolved.warnings.append(contentsOf: pathResolution.warnings)
            let url = absoluteURL(for: pathResolution.value, macros: macros)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw IdeaLightRunError.environmentFileNotFound(path: url.path)
            }
            let content: String
            do {
                content = try readFile(url)
            } catch {
                throw IdeaLightRunError.invalidConfiguration(
                    detail: "环境文件无法读取（需要 UTF-8 文本）：\(url.path)"
                )
            }
            let parsed = DotEnvParser.parse(content, environment: resolved.values)
            for (key, value) in parsed.values {
                resolved.values[key] = value
            }
            resolved.loadedFiles.append(url.path)
        }

        // §4.1: Run Configuration 的显式变量覆盖前面所有来源。字典无序，按键排序保证同输入同输出。
        for (key, rawValue) in environmentVariables.sorted(by: { $0.key < $1.key }) {
            let valueResolution = macros.resolve(rawValue)
            resolved.warnings.append(contentsOf: valueResolution.warnings)
            resolved.values[key] = valueResolution.value
        }
        return resolved
    }

    /// env 文件路径可以写相对项目根的形式（IDEA 通常写 `$PROJECT_DIR$/.env`）。
    static func absoluteURL(for path: String, macros: MacroResolver) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let projectDir = macros.projectDir {
            return projectDir.appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path)
    }
}
