import SwiftUI
import IdeaLightRunCore

/// 摘要条上的 git 区块：当前分支（点开可切换本地分支）+ 拉取按钮 + 操作结果。
/// 不是 git 仓库时整个区块隐藏。切换/拉取只影响 git，不碰运行中的服务。
struct GitControls: View {
    @StateObject private var model: GitViewModel
    /// 分支弹层的关键字过滤与显隐
    @State private var branchFilter = ""
    @State private var showsBranchPopover = false
    @FocusState private var filterFocused: Bool

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
        Button {
            branchFilter = ""
            showsBranchPopover = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(branchTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.status.blocksActions)
        .popover(isPresented: $showsBranchPopover, arrowEdge: .bottom) {
            branchPickerPopover
        }
        .help(model.currentBranch.map { "当前分支：\($0)。点开搜索并切换本地分支" } ?? "点开搜索并切换本地分支")
    }

    /// 分支选择弹层：顶部搜索框按关键字过滤，下面是过滤后的本地分支。
    /// SwiftUI 的 Menu 塞不进输入框，只能自己搭 popover。
    private var branchPickerPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索分支", text: $branchFilter)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($filterFocused)
                if !branchFilter.isEmpty {
                    Button {
                        branchFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if filteredBranches.isEmpty {
                        Text(model.branches.isEmpty ? "没有本地分支" : "没有匹配的分支")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(filteredBranches, id: \.self) { name in
                            branchRow(name)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 260, height: popoverListHeight)
        }
        .onAppear { filterFocused = true }
    }

    /// 行高 26（上下 padding 4 + 行内容）；有上限防止分支过多时弹层顶天立地。
    private var popoverListHeight: CGFloat {
        let contentHeight = filteredBranches.isEmpty
            ? CGFloat(44)
            : CGFloat(filteredBranches.count) * 26 + 8
        return min(contentHeight, 280)
    }

    private func branchRow(_ name: String) -> some View {
        let isCurrent = name == model.currentBranch
        return Button {
            showsBranchPopover = false
            model.switchBranch(name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .clear)
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || model.status.blocksActions)
        .help(isCurrent ? "当前分支" : "切换到 \(name)")
    }

    private var filteredBranches: [String] {
        let query = branchFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.branches }
        return model.branches.filter { $0.localizedCaseInsensitiveContains(query) }
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
