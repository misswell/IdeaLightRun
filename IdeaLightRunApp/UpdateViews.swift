import AppKit
import IdeaLightRunUpdate
import SwiftUI

/// 应用菜单里的「检查更新…」。放在「关于」之后是 macOS 的惯例位置；
/// 菜单项恒常可点——不可用（无网、位置只读）时点了要给原因，而不是置灰让人猜。
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Divider()
            Button("检查更新…") { AppStore.fromMenu { $0.updater.checkFromMenu() } }
        }
    }
}

struct UpdateSheet: View {
    @ObservedObject var updater: SoftwareUpdater
    /// 正在运行的服务数：更新会退出应用并连带停掉它们，必须事先说清。
    let activeSessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("检查更新").font(.headline)
                Spacer()
                Text("当前 v\(updater.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
                .padding(.vertical, 10)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 96, alignment: .topLeading)
            Divider()
                .padding(.vertical, 12)
            HStack {
                Button("打开发布页") { NSWorkspace.shared.open(updater.releasePageURL) }
                    .buttonStyle(.link)
                Spacer()
                trailingButtons
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle:
            Text("尚未开始检查。").foregroundStyle(.secondary)
        case .checking:
            busyRow("正在检查更新…")
        case .upToDate(let latest, let current):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已是最新版本")
                    Text("线上最新 v\(latest.version.description)，本机 v\(current)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .available(let release):
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("v\(release.version.description) 可下载")
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                }
                .font(.system(size: 13, weight: .semibold))
                if !release.releaseNotes.isEmpty {
                    ScrollView {
                        Text(release.releaseNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3)))
                }
                if activeSessionCount > 0 {
                    Text("安装会退出 IdeaLightRun，正在运行的 \(activeSessionCount) 个服务会一并停止。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .downloading:
            busyRow("正在下载新版本…")
        case .installing:
            VStack(alignment: .leading, spacing: 8) {
                busyRow("正在安装，应用即将退出并重启…")
                Text("请勿强制关机或断开电源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 6) {
                Label(failure.title, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(failure.reason).font(.callout)
                Text(failure.suggestion).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        switch updater.phase {
        case .available(_):
            HStack {
                Button("稍后") { updater.isPresented = false }
                Button("下载并安装") { updater.install() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .checking, .downloading(_), .installing(_):
            Button("取消") { updater.cancel() }
                .disabled(updater.phase.isInstalling)
        case .idle, .failed(_):
            HStack {
                Button("关闭") { updater.isPresented = false }
                Button("重新检查") { Task { await updater.check() } }
                    .keyboardShortcut(.defaultAction)
            }
        default:
            Button("关闭") { updater.isPresented = false }
        }
    }
}
