import Foundation

/// §12: POSIX 风格命令行分词。禁止用 /bin/sh -c 拆分参数。
/// 规则：空白分隔；双引号内允许 \" \\ \$ 转义；单引号内全部字面量；
/// 引号外反斜杠转义下一字符；相邻片段拼接（-Dname="hello world" → -Dname=hello world）。
public enum CommandLineTokenizer {
    private enum State {
        case normal
        case doubleQuoted
        case singleQuoted
    }

    public static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var state = State.normal

        var iterator = input.makeIterator()
        while let ch = iterator.next() {
            switch state {
            case .normal:
                switch ch {
                case " ", "\t", "\n", "\r":
                    if hasCurrent {
                        tokens.append(current)
                        current = ""
                        hasCurrent = false
                    }
                case "\"":
                    state = .doubleQuoted
                    hasCurrent = true
                case "'":
                    state = .singleQuoted
                    hasCurrent = true
                case "\\":
                    if let next = iterator.next() {
                        current.append(next)
                        hasCurrent = true
                    }
                default:
                    current.append(ch)
                    hasCurrent = true
                }
            case .doubleQuoted:
                switch ch {
                case "\"":
                    state = .normal
                case "\\":
                    if let next = iterator.next() {
                        switch next {
                        case "\"", "\\", "$":
                            current.append(next)
                        default:
                            current.append("\\")
                            current.append(next)
                        }
                    } else {
                        current.append("\\")
                    }
                default:
                    current.append(ch)
                }
            case .singleQuoted:
                if ch == "'" {
                    state = .normal
                } else {
                    current.append(ch)
                }
            }
        }

        if hasCurrent {
            tokens.append(current)
        }
        return tokens
    }
}
