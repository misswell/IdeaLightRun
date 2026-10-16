import SwiftUI
import IdeaLightRunCore

/// 摘要条上的 git 区块：当前分支（点开可切换本地分支）+ 拉取按钮 + 操作结果。
/// 不是 git 仓库时整个区块隐藏。切换/拉取只影响 git，不碰运行中的服务。
struct GitControls: View {
    @StateObject private var model: GitViewModel

    init(project: ProjectEntry) {
        _model = StateObject(wrappedValue: GitViewModel(projectURL: project.url))
    }

    var body: some View {
        Group {
            switch model.status {
            case .idle:
                // 非 git 仓库也占住这一行的高度：摘要条总高度在项目间来回跳更难受
                Color.clear.frame(height: 0)
            case .loading:
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                }
            case .ready, .busy:
                HStack(spacing: 10) {
                    branchMenu
                    pullButton
                    statusText
                }
            }
        }
        // 定死区块高度：busy 态的进度圈（比文字高）不再把摘要条撑高一截
        .frame(height: 20, alignment: .leading)
        .task { model.load() }
    }

    private var branchMenu: some View {
        Menu {
            if model.branches.isEmpty {
                Text("没有本地分支").foregroundStyle(.secondary)
            } else {
                ForEach(model.branches, id: \.self) { name in
                    Button {
                        model.switchBranch(name)
                    } label: {
                        if name == model.currentBranch {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                    .disabled(name == model.currentBranch)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(branchTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(model.status.blocksActions)
        .help(model.currentBranch.map { "当前分支：\($0)。点开切换本地分支" } ?? "点开切换本地分支")
    }

    private var branchTitle: String {
        if let branch = model.currentBranch { return branch }
        return model.branches.isEmpty ? "无提交" : "（分离 HEAD）"
    }

    private var pullButton: some View {
        Button {
            model.pull()
        } label: {
            Image(systemName: "arrow.down.to.line")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(model.status.blocksActions)
        .help("拉取远端更新（git pull --ff-only，只快进合并；需要当前分支有上游）")
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.status {
        case .busy(let text):
            // 进度圈限在 14pt：mini 指示器自身更高，会把整行撑高
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .ready:
            // git 独占一行，错误/提示放得下了：给足宽度，超出悬停看全文
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520, alignment: .leading)
                    .help(error)
            } else if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520, alignment: .leading)
                    .help(notice)
            }
        default:
            EmptyView()
        }
    }
}
