import Foundation
import IdeaLightRunCore

/// 摘要条上的 git 区块模型：当前分支、本地分支列表、切换与拉取。
/// git 子进程都在后台执行，结果回主线程；操作结果用行内文字展示，不用弹窗。
@MainActor
final class GitViewModel: ObservableObject {
    enum Status: Equatable {
        /// 不是 git 仓库：整个区块在 UI 里隐藏。
        case idle
        /// 正在读分支信息。
        case loading
        case ready
        /// 切换 / 拉取进行中，关联值是要显示的文字（如「正在拉取…」）。
        case busy(String)

        var blocksActions: Bool {
            switch self {
            case .busy, .loading: return true
            case .idle, .ready: return false
            }
        }
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var currentBranch: String?
    @Published private(set) var branches: [String] = []
    /// 上一步成功的提示（「已切换到 dev」/ 拉取摘要）。
    @Published private(set) var notice: String?
    /// 上一步失败的原因（git stderr 首行）。
    @Published private(set) var errorMessage: String?

    private let projectURL: URL
    private let client: GitClient

    init(projectURL: URL, client: GitClient = GitClient()) {
        self.projectURL = projectURL
        self.client = client
    }

    /// 读取仓库状态。摘要条出现（或项目重扫）时调用。
    func load() {
        status = .loading
        notice = nil
        errorMessage = nil
        let url = projectURL
        let client = self.client
        Task.detached(priority: .userInitiated) { [weak self] in
            let isRepo = client.isRepository(at: url)
            let branch = isRepo ? client.currentBranch(at: url) : nil
            let list = isRepo ? client.branches(at: url) : []
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard isRepo else {
                    self.status = .idle
                    return
                }
                self.currentBranch = branch
                self.branches = list
                self.status = .ready
            }
        }
    }

    /// 切换到本地分支。工作区有未提交修改而 git 拒绝时，错误原样展示。
    func switchBranch(_ name: String) {
        guard case .ready = status, name != currentBranch else { return }
        status = .busy("正在切换到 \(name)…")
        notice = nil
        errorMessage = nil
        let url = projectURL
        let client = self.client
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = client.checkout(name, at: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finish(result: result, successNotice: "已切换到 \(name)")
                if result.succeeded { self.load() }
            }
        }
    }

    /// 拉取远端更新（`git pull --ff-only`，需要当前分支有上游）。
    func pull() {
        guard case .ready = status else { return }
        status = .busy("正在拉取…")
        notice = nil
        errorMessage = nil
        let url = projectURL
        let client = self.client
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = client.pull(at: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let summary = GitClient.firstMeaningfulLine(result.stdout)
                let notice: String
                if summary?.hasPrefix("Already up to date") == true {
                    notice = "已是最新，远端无新提交"
                } else if let summary {
                    notice = "拉取完成：\(summary)"
                } else {
                    notice = "拉取完成"
                }
                self.finish(result: result, successNotice: notice)
            }
        }
    }

    private func finish(result: GitClient.RunResult, successNotice: String) {
        if result.succeeded {
            notice = successNotice
            errorMessage = nil
        } else {
            errorMessage = GitClient.firstMeaningfulLine(result.stderr) ?? "git 退出码 \(result.exitCode)"
            notice = nil
        }
        // 成功后 load() 会把状态从 loading 走回 ready；失败直接回 ready。
        if case .busy = status {
            status = .ready
        }
    }
}
