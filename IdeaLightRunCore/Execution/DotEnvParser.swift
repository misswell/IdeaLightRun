import Foundation

/// §4.3: `.env` 解析。IdeaLightRun 不启动 shell（禁止 `/bin/sh -c source .env`），
/// 因此这里按行自己解释赋值语句：
/// `A=1`、`B="hello world"`、`C='hello world'`、`export D=value`、`# 注释`、空行、
/// `${VAR}` 展开与双引号内的转义。
public enum DotEnvParser {
    public struct Result: Equatable, Sendable {
        public var values: [String: String]
        /// 只记行号不记内容：环境文件里的 Secret 不能进诊断日志（§17）。
        public var ignoredLineNumbers: [Int]

        public init(values: [String: String] = [:], ignoredLineNumbers: [Int] = []) {
            self.values = values
            self.ignoredLineNumbers = ignoredLineNumbers
        }
    }

    /// - Parameter environment: `${VAR}` 的展开来源；已解析出的同文件变量优先于它。
    public static func parse(_ content: String, environment: [String: String] = [:]) -> Result {
        var result = Result()
        let lines = content.split(whereSeparator: \.isNewline)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            guard let assignment = assignment(in: String(rawLine)) else {
                if !isSkippable(String(rawLine)) { result.ignoredLineNumbers.append(lineNumber) }
                continue
            }
            guard isValidKey(assignment.key) else {
                result.ignoredLineNumbers.append(lineNumber)
                continue
            }
            var lookup = environment
            for (key, value) in result.values { lookup[key] = value }
            let value = assignment.expandable ? expand(assignment.value, with: lookup) : assignment.value
            result.values[assignment.key] = value
        }
        return result
    }

    // MARK: - 内部

    private struct Assignment {
        var key: String
        var value: String
        /// 单引号内是字面量，不做 `${VAR}` 展开。
        var expandable: Bool
    }

    /// 去掉 `export ` 前缀后切分 `key=value`；不是赋值语句时返回 nil。
    private static func assignment(in line: String) -> Assignment? {
        var text = Substring(line[...])
        text = trimLeading(text)
        if text.hasPrefix("export") {
            let rest = text.dropFirst("export".count)
            guard let first = rest.first, first == " " || first == "\t" else { return nil }
            text = trimLeading(rest)
        }
        guard let separator = text.firstIndex(of: "=") else { return nil }
        let key = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
        let rawValue = text[text.index(after: separator)...]
        let (value, expandable) = valueText(from: rawValue)
        return Assignment(key: key, value: value, expandable: expandable)
    }

    private static func isSkippable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// 引号决定取值边界：双引号支持转义，单引号是字面量，裸值在行内注释前结束。
    private static func valueText(from raw: some StringProtocol) -> (String, Bool) {
        let characters = Array(raw)
        guard let index = characters.firstIndex(where: { !$0.isWhitespace }) else { return ("", true) }
        switch characters[index] {
        case "\"":
            return (doubleQuotedValue(Array(characters[(index + 1)...])), true)
        case "'":
            return (singleQuotedValue(Array(characters[(index + 1)...])), false)
        default:
            var text = String(characters[index...])
            if let commentStart = text.range(of: #"[\s]#"#, options: .regularExpression) {
                text = String(text[..<commentStart.lowerBound])
            }
            return (text.trimmingCharacters(in: .whitespaces), true)
        }
    }

    private static func doubleQuotedValue(_ characters: [Character]) -> String {
        var value = ""
        var iterator = characters.makeIterator()
        while let character = iterator.next() {
            if character == "\"" { return value }
            guard character == "\\", let escaped = iterator.next() else {
                value.append(character)
                continue
            }
            switch escaped {
            case "n": value.append("\n")
            case "r": value.append("\r")
            case "t": value.append("\t")
            case "\\", "\"", "'", "$", "`": value.append(escaped)
            default:
                value.append("\\")
                value.append(escaped)
            }
        }
        return value
    }

    private static func singleQuotedValue(_ characters: [Character]) -> String {
        var value = ""
        for character in characters {
            if character == "'" { return value }
            value.append(character)
        }
        return value
    }

    /// `${VAR}` 与 `$VAR`；未定义的引用保留原文，方便用户看出没展开的是哪一个。
    static func expand(_ value: String, with environment: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\$\\{?([A-Za-z_][A-Za-z0-9_]*)\\}?") else {
            return value
        }
        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }

        var result = value
        for match in matches.reversed() {
            let name = ns.substring(with: match.range(at: 1))
            guard let replacement = environment[name] else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func trimLeading(_ text: Substring) -> Substring {
        var slice = text
        while let first = slice.first, first == " " || first == "\t" { slice = slice.dropFirst() }
        return slice
    }
}
