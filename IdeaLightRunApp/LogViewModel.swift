import Foundation
import IdeaLightRunCore

/// 控制台数据源（§37 上限 + §103 批量）：运行会话与项目构建共用同一个
/// `LogConsoleView`，因此把"行缓冲 + 清空代数 + 绝对行号"抽成基类。
@MainActor
class LogViewModel: ObservableObject {
    /// 内存上限与 LogRingBuffer 对齐
    static let maxViewLines = 20_000

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var clearGeneration = 0

    /// lines[0] 对应的绝对行号（配合环形截断，供控制台增量渲染）。
    private(set) var firstLineIndex = 0

    func appendLog(_ line: LogLine) {
        appendLog([line])
    }

    func appendLog(_ batch: [LogLine]) {
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > Self.maxViewLines {
            let drop = lines.count - Self.maxViewLines
            lines.removeFirst(drop)
            firstLineIndex += drop
        }
    }

    func clearLogs() {
        lines = []
        firstLineIndex = 0
        clearGeneration += 1
    }
}
