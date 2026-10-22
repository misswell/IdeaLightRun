import Foundation

public struct ScanOptions: Sendable {
    /// §6: 递归 *.run.xml 最大深度 4。
    public var maxDepth: Int
    public var ignoredDirectoryNames: Set<String>

    public init(
        maxDepth: Int = 4,
        ignoredDirectoryNames: Set<String> = [".git", "target", "build", "out", "node_modules", ".gradle"]
    ) {
        self.maxDepth = maxDepth
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }
}

/// 扫描期问题：读不到的文件、损坏的 XML、读不了的配置目录、重复或缺少字段的配置。
/// 容忍错误但必须让用户看得见——静默丢配置等于把 IDEA 配置藏起来。
public struct ScanDiagnostic: Equatable, Hashable, Codable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable {
        case info
        case warning
        case error

        /// 列表按严重程度倒序；同级别再按文件/消息稳定排序。
        var sortRank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .info: return 2
            }
        }
    }

    public var file: URL
    public var severity: Severity
    public var message: String
    /// 用户能照做的一句话；没有可靠建议时留空，不用空话凑数。
    public var remediation: String?

    public var id: String { "\(severity.rawValue)|\(file.path)|\(message)" }

    public init(file: URL, severity: Severity, message: String, remediation: String? = nil) {
        self.file = file
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

public struct ScanResult: Equatable, Codable, Sendable {
    public var projectRoot: URL
    public var configurations: [RunConfiguration]
    public var ignoredDuplicateCount: Int
    public var buildSystem: BuildSystemDetection
    public var projectJDKName: String?
    public var modules: [ProjectModule]
    public var diagnostics: [ScanDiagnostic]

    public init(
        projectRoot: URL,
        configurations: [RunConfiguration],
        ignoredDuplicateCount: Int,
        buildSystem: BuildSystemDetection,
        projectJDKName: String?,
        modules: [ProjectModule],
        diagnostics: [ScanDiagnostic] = []
    ) {
        self.projectRoot = projectRoot
        self.configurations = configurations
        self.ignoredDuplicateCount = ignoredDuplicateCount
        self.buildSystem = buildSystem
        self.projectJDKName = projectJDKName
        self.modules = modules
        self.diagnostics = diagnostics
    }
}

/// §5/§6: 项目扫描入口。扫描顺序与去重优先级见 §7。
public struct IntelliJProjectScanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = .init()) {
        self.options = options
    }

    public func scan(projectRoot: URL) throws -> ScanResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IdeaLightRunError.projectNotFound(path: projectRoot.path)
        }

        var found: [RunConfiguration] = []
        var diagnostics: [ScanDiagnostic] = []
        let fm = FileManager.default

        // 优先级 1：.run/*.run.xml
        let dotRunDir = projectRoot.appendingPathComponent(".run", isDirectory: true)
        for file in listXMLFiles(in: dotRunDir, suffix: "run.xml", diagnostics: &diagnostics) {
            collectProjectConfigurations(from: file, kind: .dotRun, into: &found, diagnostics: &diagnostics)
        }

        // 优先级 2：project/**/*.run.xml（深度 ≤ maxDepth）
        for file in recursiveRunXMLFiles(in: projectRoot, diagnostics: &diagnostics) {
            collectProjectConfigurations(from: file, kind: .projectRunXML, into: &found, diagnostics: &diagnostics)
        }

        // 优先级 3：.idea/runConfigurations/*.xml
        let runConfigurationsDir = projectRoot.appendingPathComponent(".idea/runConfigurations", isDirectory: true)
        for file in listXMLFiles(in: runConfigurationsDir, suffix: "xml", diagnostics: &diagnostics) {
            collectProjectConfigurations(from: file, kind: .ideaRunConfigurations, into: &found, diagnostics: &diagnostics)
        }

        // 优先级 4：.idea/workspace.xml
        let workspaceFile = projectRoot.appendingPathComponent(".idea/workspace.xml")
        if fm.fileExists(atPath: workspaceFile.path) {
            do {
                let outcome = try WorkspaceRunConfigurationParser.parseOutcome(fileURL: workspaceFile)
                found.append(contentsOf: outcome.configurations)
                if let message = outcome.xmlErrorMessage {
                    diagnostics.append(ScanDiagnostic(
                        file: workspaceFile,
                        severity: .warning,
                        message: "XML 格式错误，已尽力读取 \(outcome.configurations.count) 个配置：\(message)"
                    ))
                }
            } catch {
                diagnostics.append(ScanDiagnostic(
                    file: workspaceFile,
                    severity: .error,
                    message: "无法读取运行配置文件：\(error.localizedDescription)"
                ))
            }
        }

        // §7: 唯一键 type + name，按来源优先级去重。
        var best: [String: RunConfiguration] = [:]
        var duplicateCount = 0
        for config in found {
            if let existing = best[config.uniqueKey] {
                duplicateCount += 1
                let kept: RunConfiguration
                let discarded: RunConfiguration
                if prefer(config, over: existing) {
                    kept = config
                    discarded = existing
                    best[config.uniqueKey] = config
                } else {
                    kept = existing
                    discarded = config
                }
                diagnostics.append(ScanDiagnostic(
                    file: discarded.source.file,
                    severity: .info,
                    message: "配置“\(discarded.name)”与同名配置重复，已采用 \(kept.source.file.path)"
                        + "（来源优先级更高或修改时间更新）。",
                    remediation: "在 IDEA 中删除或重命名重复配置，避免改动被另一份覆盖。"
                ))
            } else {
                best[config.uniqueKey] = config
            }
        }

        let configurations = best.values.sorted { lhs, rhs in
            if lhs.type.sortRank != rhs.type.sortRank {
                return lhs.type.sortRank < rhs.type.sortRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        collectConfigurationDiagnostics(from: configurations, into: &diagnostics)

        return ScanResult(
            projectRoot: projectRoot,
            configurations: configurations,
            ignoredDuplicateCount: duplicateCount,
            buildSystem: BuildSystemDetector.detect(projectRoot: projectRoot),
            projectJDKName: IntelliJSDKReader.readProjectSDK(projectRoot: projectRoot)?.name,
            modules: ModuleResolver.collectModules(projectRoot: projectRoot),
            diagnostics: diagnostics.sorted {
                if $0.severity.sortRank != $1.severity.sortRank {
                    return $0.severity.sortRank < $1.severity.sortRank
                }
                if $0.file.path != $1.file.path { return $0.file.path < $1.file.path }
                return $0.message < $1.message
            }
        )
    }

    /// 扫描能保住配置，但保不住“这份配置能不能跑”。缺字段与不支持的任务
    /// 必须随扫描结果一起出现，不能等用户点了 Run 才在控制台里撞墙。
    private func collectConfigurationDiagnostics(
        from configurations: [RunConfiguration],
        into diagnostics: inout [ScanDiagnostic]
    ) {
        for config in configurations {
            for warning in config.warnings {
                switch warning {
                case .missingMainClass:
                    diagnostics.append(ScanDiagnostic(
                        file: config.source.file,
                        severity: .warning,
                        message: "配置“\(config.name)”缺少 Main Class，无法启动。",
                        remediation: "在 IDEA 的运行配置中填写 Main class，或改用 Application / Spring Boot 配置。"
                    ))
                case .missingJarPath:
                    diagnostics.append(ScanDiagnostic(
                        file: config.source.file,
                        severity: .warning,
                        message: "配置“\(config.name)”缺少 JAR Path，无法启动。",
                        remediation: "在 IDEA 的 JAR Application 配置中选择可执行 JAR 文件。"
                    ))
                case .unsupportedBeforeLaunch(let description):
                    diagnostics.append(ScanDiagnostic(
                        file: config.source.file,
                        severity: .warning,
                        message: "配置“\(config.name)”包含当前版本不支持的 Before Launch 任务：\(description)。",
                        remediation: "在 IDEA 中停用该任务，或改用 Make / Build Project / Maven Goal / Run Another Configuration。"
                    ))
                default:
                    break
                }
            }

            for task in config.beforeLaunchTasks where task.isEnabled {
                switch task.kind {
                case .gradleTask(let taskName):
                    diagnostics.append(ScanDiagnostic(
                        file: config.source.file,
                        severity: .warning,
                        message: "配置“\(config.name)”的 Before Launch Gradle 任务“\(taskName)”当前版本尚未接管。",
                        remediation: "暂时在 IDEA 中停用该 Gradle 任务；Gradle 构建支持将在后续版本接入。"
                    ))
                case .mavenGoal(let goal, _) where goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    diagnostics.append(ScanDiagnostic(
                        file: config.source.file,
                        severity: .warning,
                        message: "配置“\(config.name)”的 Before Launch Maven Goal 为空，执行时会被拒绝。",
                        remediation: "在 IDEA 中补全 Maven Goal，或停用该任务。"
                    ))
                default:
                    break
                }
            }
        }
    }

    /// `try?` 会把"文件读不了"和"文件里没有配置"混为一谈：前者必须留下诊断。
    private func collectProjectConfigurations(
        from file: URL,
        kind: ConfigurationSource.Kind,
        into found: inout [RunConfiguration],
        diagnostics: inout [ScanDiagnostic]
    ) {
        do {
            let outcome = try ProjectRunConfigurationParser.parseOutcome(fileURL: file, kind: kind)
            found.append(contentsOf: outcome.configurations)
            if let message = outcome.xmlErrorMessage {
                diagnostics.append(ScanDiagnostic(
                    file: file,
                    severity: .warning,
                    message: "XML 格式错误，已尽力读取 \(outcome.configurations.count) 个配置：\(message)"
                ))
            }
        } catch {
            diagnostics.append(ScanDiagnostic(
                file: file,
                severity: .error,
                message: "无法读取运行配置文件：\(error.localizedDescription)"
            ))
        }
    }

    private func prefer(_ a: RunConfiguration, over b: RunConfiguration) -> Bool {
        if a.source.kind != b.source.kind {
            return a.source.kind.rawValue < b.source.kind.rawValue
        }
        let aModified = a.source.modifiedAt ?? .distantPast
        let bModified = b.source.modifiedAt ?? .distantPast
        return aModified > bModified
    }

    private func listXMLFiles(
        in directory: URL,
        suffix: String,
        diagnostics: inout [ScanDiagnostic]
    ) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            diagnostics.append(ScanDiagnostic(
                file: directory,
                severity: .warning,
                message: "无法读取配置目录：\(error.localizedDescription)"
            ))
            return []
        }
        return entries
            .filter { !$0.hasDirectoryPath && $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.path < $1.path }
    }

    private func recursiveRunXMLFiles(in root: URL, diagnostics: inout [ScanDiagnostic]) -> [URL] {
        var results: [URL] = []
        let dotRunDir = root.appendingPathComponent(".run", isDirectory: true)

        func walk(_ directory: URL, depth: Int) {
            guard depth <= options.maxDepth else { return }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                )
            } catch {
                diagnostics.append(ScanDiagnostic(
                    file: directory,
                    severity: .warning,
                    message: "无法读取目录，已跳过其中的运行配置：\(error.localizedDescription)"
                ))
                return
            }
            for entry in entries {
                if options.ignoredDirectoryNames.contains(entry.lastPathComponent) { continue }
                if entry.standardizedFileURL == dotRunDir.standardizedFileURL { continue }
                if entry.hasDirectoryPath {
                    walk(entry, depth: depth + 1)
                } else if entry.lastPathComponent.hasSuffix(".run.xml") {
                    results.append(entry)
                }
            }
        }

        walk(root, depth: 0)
        return results.sorted { $0.path < $1.path }
    }
}
