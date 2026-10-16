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
                EmptyView()
            case .loading:
                chip(ProgressView().controlSize(.mini))
            case .ready, .busy:
                HStack(spacing: 10) {
                    branchMenu
                    pullButton
                    statusText
                }
            }
        }
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
            ProgressView()
                .controlSize(.mini)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                    .help(error)
            } else if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                    .help(notice)
            }
        default:
            EmptyView()
        }
    }

    private func chip(_ content: some View) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            content
        }
    }
}
