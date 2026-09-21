import Foundation

/// §5: 宏解析集中在这里。以前各处写 `resolver.resolve(x).value`，warning 随返回值一起被丢掉，
/// 用户看到的是"带着没展开的 $Prompt$ 照常启动"。现在解析结果统一进 `ResolvedRunConfiguration`，
/// 关键字段里残留的 IDEA 上下文宏直接禁止启动。
public struct RunConfigurationResolver: Sendable {
    public init() {}

    public func resolve(
        config: RunConfiguration,
        projectRoot: URL,
        module: ProjectModule?,
        jdk: JDKInstallation? = nil,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedRunConfiguration {
        let moduleDirectory = module?.directory
        let macros = MacroResolver(projectDir: projectRoot, moduleDir: moduleDirectory)
        var warnings = config.warnings

        func resolveField(_ raw: String) -> String {
            let resolution = macros.resolve(raw)
            for warning in resolution.warnings {
                MacroResolver.appendWarning(warning, into: &warnings)
            }
            return resolution.value
        }

        // §12/§11: VM Options 先分词再展开，保证带空格的值仍是一个参数。
        var vmArguments: [String] = []
        if let vmOptions = config.vmOptions {
            vmArguments += CommandLineTokenizer.tokenize(vmOptions).map(resolveField)
        }
        // §29: profiles 已显式存在时不重复注入
        if !config.springProfiles.isEmpty,
           !vmArguments.contains(where: { $0.hasPrefix("-Dspring.profiles.active") }) {
            vmArguments.append("-Dspring.profiles.active=" + config.springProfiles.joined(separator: ","))
        }

        let programArguments: [String]
        if let raw = config.programArguments {
            programArguments = CommandLineTokenizer.tokenize(raw).map(resolveField)
        } else {
            programArguments = []
        }

        // §4.1: System < Env File 1 < … < Run Configuration env
        let environment = try EnvironmentResolver.resolve(
            passParentEnvironment: config.passParentEnvironment,
            environmentFiles: config.environmentFiles,
            environmentVariables: config.environmentVariables,
            macros: macros,
            parentEnvironment: parentEnvironment
        )
        for warning in environment.warnings {
            MacroResolver.appendWarning(warning, into: &warnings)
        }

        var mainClass: String?
        if let raw = config.mainClass?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            mainClass = resolveField(raw)
        }

        let workingDirectoryPath: String
        if let raw = config.workingDirectory, !raw.isEmpty {
            workingDirectoryPath = resolveField(raw)
        } else {
            workingDirectoryPath = (moduleDirectory ?? projectRoot).path
        }

        // 致命宏判定放在目录存在性检查之前：配置依赖 IDEA 上下文时，
        // 先说清"这个值解析不了"，不要用一个次要的路径错误盖掉真正的原因。
        try Self.rejectUnresolvedMacros(warnings: warnings, configName: config.name)

        let workingDirectory = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IdeaLightRunError.launchFailed(detail: "Working Directory 不存在：\(workingDirectory.path)（原始值：\(config.workingDirectory ?? "-")）")
        }

        return ResolvedRunConfiguration(
            source: config,
            mainClass: mainClass,
            module: module,
            jdk: jdk,
            vmArguments: vmArguments,
            programArguments: programArguments,
            environment: environment.values,
            workingDirectory: workingDirectory,
            warnings: warnings,
            loadedEnvironmentFiles: environment.loadedFiles
        )
    }

    // MARK: - 致命宏判定（§5）

    /// `$Prompt$` / `$FilePath$` / `$SelectedText$` 依赖 IDEA 的运行期上下文，
    /// 无法伪造；形如 `$UPPER_CASE$` 的未知宏同样是 IDEA 宏，不能带着原文启动。
    /// 其他 `$lowercase` / Spring 占位符（`${random.value}`）只告警，不阻止启动。
    static func rejectUnresolvedMacros(warnings: [ConfigurationWarning], configName: String) throws {
        var contextTokens: [String] = []
        var macroTokens: [String] = []
        for warning in warnings {
            switch warning {
            case .ideaContextMacro(let name, _):
                appendUnique("$\(name)$", into: &contextTokens)
            case .unresolvedMacro(let token, _):
                guard isIDEAMacroShape(token) else { continue }
                appendUnique(token, into: &macroTokens)
            default:
                break
            }
        }

        if !contextTokens.isEmpty {
            throw IdeaLightRunError.unresolvedIdeaContextMacro(
                detail: "配置 “\(configName)” 依赖 IDEA 当前上下文（\(contextTokens.joined(separator: "、"))），"
                    + "IdeaLightRun 无法自动解析这些值。请在 IDEA 中把对应字段改成字面量。"
            )
        }
        if !macroTokens.isEmpty {
            throw IdeaLightRunError.unresolvedMacro(
                detail: "配置 “\(configName)” 含无法解析的 IDEA 宏：\(macroTokens.joined(separator: "、"))。"
            )
        }
    }

    private static func appendUnique(_ token: String, into list: inout [String]) {
        guard !list.contains(token) else { return }
        list.append(token)
    }

    static func isIDEAMacroShape(_ token: String) -> Bool {
        token.firstMatch(of: #/^\$[A-Z][A-Z0-9_]*\$$/#) != nil
    }
}
