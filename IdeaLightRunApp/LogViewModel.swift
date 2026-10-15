import Foundation
import IdeaLightRunCore

/// 控制台的来源筛选档位。「全部」之外的档位直接映射到同名的 LogStream。
enum ConsoleStreamFilter: String, CaseIterable, Hashable {
    case all
    case stdout
    case stderr
    case system

    var title: String {
        switch self {
        case .all: return "全部"
        case .stdout: return "输出"
        case .stderr: return "错误"
        case .system: return "系统"
        }
    }

    var source: LogStream? {
        self == .all ? nil : LogStream(rawValue: rawValue)
    }
}

/// 控制台的行筛选：内容关键字（忽略大小写）+ 来源档位。
/// 未命中的行从显示里过滤掉；只影响显示，不改变
/// LogRingBuffer / LogViewModel 的保留上限（§37）。
struct ConsoleFilter: Equatable {
    var filterText: String = ""
    var stream: ConsoleStreamFilter = .all

    var isActive: Bool { !filterText.isEmpty || stream != .all }

    func matches(_ line: LogLine) -> Bool {
        if let source = stream.source, line.stream != source { return false }
        if !filterText.isEmpty,
           line.text.range(of: filterText, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }
}

/// 控制台数据源（§37 上限 + §103 批量）：运行会话与项目构建共用同一个
/// `LogConsoleView`，因此把"行缓冲 + 清空代数 + 绝对行号"抽成基类。
@MainActor
class LogViewModel: ObservableObject {
    /// 内存上限与 LogRingBuffer 对齐
    static let maxViewLines = 20_000

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var clearGeneration = 0
    /// 行筛选（漏斗）。放在模型而不是视图本地 @State：切换信息/控制台页签会销毁视图，
    /// 回来时条件应当保持原样。
    @Published var displayFilter = ConsoleFilter()
    /// 搜索关键词：只做高亮与上一个/下一个定位，不参与行筛选。
    @Published var searchText = ""
    /// 当前命中的匹配序号（0 基），▲▼ 在匹配之间跳转。
    @Published var searchCurrentIndex = 0

    /// lines[0] 对应的绝对行号（配合环形截断，供控制台增量渲染）。
    private(set) var firstLineIndex = 0

    /// 当前筛选下的可见行数（筛选条上的「M / N 行」）。
    var visibleLineCount: Int {
        guard displayFilter.isActive else { return lines.count }
        return lines.filter { displayFilter.matches($0) }.count
    }

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
