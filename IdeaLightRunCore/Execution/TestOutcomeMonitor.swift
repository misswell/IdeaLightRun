import Foundation

/// 一次测试运行的汇总。Maven 解析 Surefire 的 `Results:` 段，
/// Gradle 解析测试 init script 打印的 `[IdeaLightRun-Test] SUMMARY` 标记。
public struct TestRunSummary: Equatable, Sendable {
    public var total: Int
    public var failures: Int
    public var errors: Int
    public var skipped: Int
    /// 是否真的拿到了测试汇总（与“汇总为 0 个测试”不同）。
    public var hasReport: Bool
    /// 运行器明确报告“没有匹配的测试 / 没有测试可运行”。
    public var noTestsDetected: Bool

    public init(
        total: Int = 0,
        failures: Int = 0,
        errors: Int = 0,
        skipped: Int = 0,
        hasReport: Bool = false,
        noTestsDetected: Bool = false
    ) {
        self.total = total
        self.failures = failures
        self.errors = errors
        self.skipped = skipped
        self.hasReport = hasReport
        self.noTestsDetected = noTestsDetected
    }

    public var failedCount: Int { failures + errors }
    public var didRunAnyTest: Bool { hasReport && total > 0 }

    mutating func merge(_ other: TestRunSummary) {
        total += other.total
        failures += other.failures
        errors += other.errors
        skipped += other.skipped
    }

    public var detailText: String {
        "共 \(total) 个，失败 \(failures)，错误 \(errors)，跳过 \(skipped)"
    }
}

/// 实时消费构建日志，提取测试计数。线程安全：日志回调来自读线程 / flush 队列。
public final class TestOutcomeMonitor: @unchecked Sendable {
    private let lock = NSLock()

    private var mavenTotals = TestRunSummary()
    private var mavenHasReport = false
    private var awaitingMavenResults = false
    private var mavenFallback: TestRunSummary?

    private var gradleTotals = TestRunSummary()
    private var gradleHasReport = false

    private var noTestsDetected = false

    public init() {}

    public func consume(_ lines: [LogLine]) {
        lock.lock()
        defer { lock.unlock() }
        for line in lines {
            consumeLocked(line.text)
        }
    }

    public func consume(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        consumeLocked(text)
    }

    public func snapshot() -> TestRunSummary {
        lock.lock()
        defer { lock.unlock() }
        var summary: TestRunSummary
        if gradleHasReport {
            summary = gradleTotals
            summary.hasReport = true
        } else if mavenHasReport {
            summary = mavenTotals
            summary.hasReport = true
        } else if let fallback = mavenFallback {
            summary = fallback
            summary.hasReport = true
        } else {
            summary = TestRunSummary()
        }
        summary.noTestsDetected = noTestsDetected
        return summary
    }

    // MARK: - 解析

    private func consumeLocked(_ rawLine: String) {
        let line = stripLogPrefixes(rawLine)
        let lowercased = line.lowercased()

        if lowercased.contains("no tests to run")
            || lowercased.contains("no tests were executed")
            || lowercased.contains("no tests found for given includes")
            || lowercased.contains("no tests matching pattern")
            || lowercased.contains("no matching tests") {
            noTestsDetected = true
        }
        if line.contains("> Task"), line.contains("NO-SOURCE"), lowercased.contains("test") {
            noTestsDetected = true
        }
        if line.contains("> Task"), line.contains(" SKIPPED"), lowercased.contains("test") {
            noTestsDetected = true
        }

        // 旧版 Surefire 打印 "Results :"（冒号前有空格），新版是 "Results:"。
        if line.replacingOccurrences(of: " ", with: "") == "Results:" {
            awaitingMavenResults = true
        }

        if line.contains("Tests run:"), let summary = Self.parseMavenCounts(line) {
            mavenFallback = summary
            if awaitingMavenResults {
                // Maven 多模块时每个模块都有一个 Results 段；逐段累加才是总数。
                mavenTotals.merge(summary)
                mavenHasReport = true
                awaitingMavenResults = false
            }
        }

        if line.contains("[IdeaLightRun-Test] SUMMARY"), let summary = Self.parseGradleSummary(line) {
            gradleTotals.merge(summary)
            gradleHasReport = true
        }
    }

    static func parseMavenCounts(_ line: String) -> TestRunSummary? {
        guard let regex = try? NSRegularExpression(
            pattern: "Tests run: (\\d+), Failures: (\\d+), Errors: (\\d+), Skipped: (\\d+)"
        ) else {
            return nil
        }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return TestRunSummary(
            total: Int(ns.substring(with: match.range(at: 1))) ?? 0,
            failures: Int(ns.substring(with: match.range(at: 2))) ?? 0,
            errors: Int(ns.substring(with: match.range(at: 3))) ?? 0,
            skipped: Int(ns.substring(with: match.range(at: 4))) ?? 0,
            hasReport: true
        )
    }

    static func parseGradleSummary(_ line: String) -> TestRunSummary? {
        func value(_ name: String) -> Int? {
            guard let range = line.range(of: "\(name)=") else { return nil }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }
        guard let total = value("total"), let failed = value("failed"), let skipped = value("skipped") else {
            return nil
        }
        return TestRunSummary(
            total: total,
            failures: failed,
            errors: 0,
            skipped: skipped,
            hasReport: true
        )
    }

    private func stripLogPrefixes(_ raw: String) -> String {
        var line = raw
        // ANSI 颜色（Maven 在 CI/特定终端下可能加粗）。
        if let ansi = try? NSRegularExpression(pattern: "\\u{001B}\\[[0-9;]*m") {
            line = ansi.stringByReplacingMatches(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length),
                withTemplate: ""
            )
        }
        for prefix in ["[INFO]", "[ERROR]", "[WARNING]", "[WARN]"] {
            if line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return line
    }
}
