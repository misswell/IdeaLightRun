import Foundation

public struct MacroResolution: Equatable, Codable, Sendable {
    public var value: String
    public var warnings: [ConfigurationWarning]

    public init(value: String, warnings: [ConfigurationWarning]) {
        self.value = value
        self.warnings = warnings
    }
}

/// §11: IDEA 宏解析。依赖 IDEA 运行时上下文的宏（$Prompt$ 等）不伪造，
/// 只产生 warning 并保留原文。
public struct MacroResolver: Sendable {
    public let projectDir: URL?
    public let workspaceDir: URL?
    public let moduleDir: URL?
    public let userHome: URL
    public let environment: [String: String]

    /// 依赖 IDEA 编辑器上下文、无法在外部可靠推导的宏。它们必须保留原文并告警，
    /// 绝不能因为环境里恰好有同名变量就被替换成语义不同的值。
    public static let ideaContextMacroNames: Set<String> = [
        "Prompt", "FilePath", "FileDir", "FileName", "FileExt",
        "SelectedText", "ClipboardContent", "LineNumber", "ColumnNumber",
    ]

    public init(
        projectDir: URL?,
        workspaceDir: URL? = nil,
        moduleDir: URL? = nil,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.projectDir = projectDir
        self.workspaceDir = workspaceDir
        self.moduleDir = moduleDir
        self.userHome = userHome
        self.environment = environment
    }

    public func resolve(_ raw: String) -> MacroResolution {
        var warnings: [ConfigurationWarning] = []
        var result = raw

        // 1) IDEA 内置宏。先替换长的，避免 token 之间前缀干扰。
        let ideaMacros: [(token: String, value: String?)] = [
            ("$MODULE_WORKING_DIR$", moduleDir?.path),
            ("$MODULE_DIR$", moduleDir?.path),
            ("$PROJECT_DIR$", projectDir?.path),
            // IDEA 的 JUnit / Maven 配置在 PATH 类字段里使用 %...% 变体。
            ("%MODULE_WORKING_DIR%", moduleDir?.path),
            ("%MODULE_DIR%", moduleDir?.path),
            ("%PROJECT_DIR%", projectDir?.path),
            // JUnit 的目录选择器保存 file URL 时仍可能带 IDEA 的路径宏。
            ("$ProjectFileDir$", projectDir?.path),
            ("$PROJECT_NAME$", projectDir?.lastPathComponent),
            ("$WORKSPACE_DIR$", (workspaceDir ?? projectDir)?.path),
            ("$USER_HOME$", userHome.path),
            ("$TEMP_DIR$", FileManager.default.temporaryDirectory.path),
            ("$USER$", NSUserName()),
            ("$HOST$", ProcessInfo.processInfo.hostName),
        ]
        for (token, value) in ideaMacros {
            guard result.contains(token) else { continue }
            if let value {
                result = result.replacingOccurrences(of: token, with: value)
            } else {
                Self.appendWarning(.unresolvedMacro(token: token, rawValue: raw), into: &warnings)
            }
        }

        // 2) ${VAR} 环境变量
        result = replaceEnvironmentReferences(
            in: result,
            pattern: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}",
            rawValue: raw,
            warnings: &warnings
        )

        // 3) $VAR$ 环境变量（剩余的 $X$ 形式）。IDEA 上下文宏优先于同名环境变量：
        //    否则 $SelectedText$ 会被环境里的 SelectedText 静默顶替，语义就错了。
        result = replaceEnvironmentReferences(
            in: result,
            pattern: "\\$([A-Za-z_][A-Za-z0-9_]*)\\$",
            rawValue: raw,
            warnings: &warnings,
            contextMacrosTakePrecedence: true
        )

        return MacroResolution(value: result, warnings: warnings)
    }

    private func replaceEnvironmentReferences(
        in string: String,
        pattern: String,
        rawValue: String,
        warnings: inout [ConfigurationWarning],
        contextMacrosTakePrecedence: Bool = false
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let ns = string as NSString
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return string }

        var result = string
        // 从后往前替换，保持前面 match 的 offset 有效。
        for match in matches.reversed() {
            let name = ns.substring(with: match.range(at: 1))
            if contextMacrosTakePrecedence, Self.ideaContextMacroNames.contains(name) {
                Self.appendWarning(.ideaContextMacro(name: name, rawValue: rawValue), into: &warnings)
            } else if let value = environment[name] {
                result = (result as NSString).replacingCharacters(in: match.range, with: value)
            } else if Self.ideaContextMacroNames.contains(name) {
                Self.appendWarning(.ideaContextMacro(name: name, rawValue: rawValue), into: &warnings)
            } else {
                let token = ns.substring(with: match.range)
                Self.appendWarning(.unresolvedMacro(token: token, rawValue: rawValue), into: &warnings)
            }
        }
        return result
    }

    static func appendWarning(_ warning: ConfigurationWarning, into warnings: inout [ConfigurationWarning]) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
    }
}
