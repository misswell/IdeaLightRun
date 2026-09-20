import Foundation
import IdeaLightRunCore

/// 一次项目级构建（IDEA 的 Build / Rebuild Project、Maven clean）的 GUI 侧模型。
/// 构建只产出结果、没有常驻进程，因此不复用 `ProcessState`：
/// "已退出 (0)"这类运行期概念用在构建上只会误导用户。
@MainActor
final class ProjectBuildModel: LogViewModel {
    enum Phase: Equatable {
        case running
        case stopping
        case succeeded(TimeInterval)
        case cancelled
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .running, .stopping: return true
            case .succeeded, .cancelled, .failed: return false
            }
        }
    }

    let projectPath: String
    let kind: ProjectBuildKind
    @Published private(set) var phase: Phase

    /// Maven 子进程句柄："停止构建"用它发 SIGTERM，卡死时兜底 SIGKILL。
    var handle: ProcessHandle?

    /// 嵌套 ObservableObject 不会自动冒泡，必须显式通知 AppStore（同 RunningProcessModel）。
    var onChange: (() -> Void)?

    private let startedAt = Date()

    init(projectPath: String, kind: ProjectBuildKind) {
        self.projectPath = projectPath
        self.kind = kind
        self.phase = .running
        super.init()
    }

    /// 状态文字跟着动作走：清理完显示"构建成功"会让人以为编译过了。
    var statusText: String {
        switch phase {
        case .running: return "\(kind.actionName)中"
        case .stopping: return "停止中"
        case .succeeded(let seconds): return String(format: "%@成功 (%.1fs)", kind.actionName, seconds)
        case .cancelled: return "已停止"
        case .failed: return "\(kind.actionName)失败"
        }
    }

    func markStopping() {
        update(to: .stopping)
    }

    func succeed() {
        update(to: .succeeded(Date().timeIntervalSince(startedAt)))
    }

    func cancel() {
        update(to: .cancelled)
    }

    /// 失败原因同时落到构建输出末尾，用户不必把鼠标停在状态文字上找原因。
    func fail(_ message: String) {
        appendLog(LogLine(stream: .system, text: "[IdeaLightRun] \(message)"))
        update(to: .failed(message))
    }

    private func update(to newPhase: Phase) {
        phase = newPhase
        onChange?()
    }
}
