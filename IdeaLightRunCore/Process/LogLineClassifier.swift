import Foundation

/// 控制台行的展示分类。对齐 IDEA 控制台的行为：不能只看 stdout/stderr——
/// Spring Boot（Logback 默认配置）把日志连同堆栈一起写进 stdout，
/// 按"流"着色时整段异常栈都是普通白色，报错完全看不出来。
/// IDEA 是按内容识别：异常头 / Caused by / ERROR 级别行标红，`at` 帧行标链接蓝。
public enum LogLineKind: Equatable, Sendable {
    case normal
    /// 异常头、Caused by / Suppressed、日志里的 ERROR 级别行，以及全部 stderr。
    case error
    /// 堆栈帧（`at com.foo.Bar.run(Bar.java:12)`）与「... 53 more」折叠行。
    case frame
}

public enum LogLineClassifier {
    // `at` 帧要求点分的 类.方法( ...)，避免把英文句子 "at least one (try)" 当成帧；
    // 括号后允许 logback 的 ` ~[spring-web-5.3.39.jar:5.3.39]` 尾巴（不锚定行尾）。
    private static let frameRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*at[ \t]+[A-Za-z_$][A-Za-z0-9_$<>]*(\.[A-Za-z0-9_$<>]+)+\(.+\)"# +
            #"|^[ \t]*\.\.\.[ \t]*\d+[ \t]+(\bmore\b|common frames)"#
    )
    // 异常头 / Caused by / Suppressed / 点分异常类名（末段以 Exception|Error 结尾，
    // 如 java.lang.NullPointerException）/ 大写 ERROR 级别（区分于 "0 errors"）。
    private static let errorRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(Caused by|Suppressed):"# +
            #"|^[ \t]*Exception\b"# +
            #"|\.[A-Za-z0-9_$]*(Exception|Error)\b"# +
            #"|\bERROR\b"#
    )

    public static func kind(stream: LogStream, text: String) -> LogLineKind {
        switch stream {
        case .stderr: return .error
        case .system: return .normal
        case .stdout: break
        }
        if isFrame(text) { return .frame }
        if isError(text) { return .error }
        return .normal
    }

    private static func isFrame(_ text: String) -> Bool {
        guard text.contains("(") || text.contains("...") else { return false }
        return matches(frameRegex, text)
    }

    private static func isError(_ text: String) -> Bool {
        guard text.contains("Exception") || text.contains("Error") || text.contains("ERROR")
                || text.contains("Caused by") || text.contains("Suppressed") else { return false }
        return matches(errorRegex, text)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
