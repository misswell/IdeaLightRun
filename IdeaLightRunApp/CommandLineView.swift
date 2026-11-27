import AppKit
import IdeaLightRunCore
import SwiftUI

/// 右侧「命令行模式」：项目级、手写命令。
/// 它只替换右栏内容，左侧项目列表和中栏配置列表都保持原样；
/// 顶栏与内容区都提供「返回配置」入口，不会出现退不回配置模式的状态。
struct CommandLineView: View {
    @ObservedObject var store: AppStore
    let project: ProjectEntry

    @State private var settings: CommandLineSettings = .empty
    @State private var showEnvironment = false
    @State private var showDirectoryPicker = false

    private var activeModel: RunningProcessModel? {
        store.commandLineActiveSessions(projectID: project.id).first
    }

    /// 运行中保留上一次终态会话，用户能看到退出码与日志。
    private var displayModel: RunningProcessModel? {
        store.commandLineSession(projectID: project.id)
    }

    private var canRun: Bool {
        settings.isRunnable && activeModel == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            form
                .layoutPriority(1)
            Divider()
            console
        }
        .task(id: project.id) {
            settings = store.commandLineSettings(forProject: project.id)
        }
        .fileImporter(
            isPresented: $showDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                updateSettings { $0.workingDirectory = url.path }
            }
        }
    }

    // MARK: - 命令行输入区

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("命令行", systemImage: "terminal")
                    .font(.headline)
                if let model = displayModel {
                    statusBadge(model)
                }
                Spacer(minLength: 8)
                if let model = displayModel, let pid = model.pid {
                    Text("PID \(pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // 终端输入块：命令是这一行的主体，不再被工作目录、按钮等挤到看不见。
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                TextField("输入命令，例如 npm run dev、python3 app.py、./scripts/dev.sh", text: commandBinding)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(run)
                    .help("按回车运行。命令通过登录 zsh 执行，支持管道、&&、变量与别名。")
                Button(action: run) {
                    Label("运行", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canRun)
                .help(canRun ? "启动这条命令（⌘R）" : "先输入命令，或等待当前命令结束")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor))
            )

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                TextField(project.url.path, text: workingDirectoryBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .help("留空使用项目根目录；支持 ~、$PROJECT_DIR$ 与相对路径")
                Button {
                    showDirectoryPicker = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("选择工作目录")
                if !settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("项目根") {
                        updateSettings { $0.workingDirectory = "" }
                    }
                    .help("恢复为项目根目录")
                }
                Button {
                    showEnvironment = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("环境变量")
                        if !settings.environmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                        }
                    }
                }
                .help("设置该命令的环境变量")
                .popover(isPresented: $showEnvironment, arrowEdge: .bottom) {
                    environmentEditor
                }
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    store.stopCommandLine(projectID: project.id)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(activeModel?.state.isActive == true) || activeModel?.state == .stopping)
                .help("向整棵进程树发送 SIGTERM（⌘.）")

                if activeModel?.state == .stopping {
                    Button(role: .destructive) {
                        store.forceKillCommandLine(projectID: project.id)
                    } label: {
                        Label("强制结束", systemImage: "xmark.octagon.fill")
                    }
                    .help("强制结束（SIGKILL）")
                }

                Button {
                    store.restartCommandLine(projectID: project.id)
                } label: {
                    Label("重启", systemImage: "arrow.triangle.2.circlepath")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(restartDisabled)
                .help("停止旧进程退出后再运行同一条命令（⇧⌘R）")

                Spacer(minLength: 8)
                Text("登录 zsh · 支持管道与 && · 不支持 sudo 等终端交互")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .controlSize(.small)
        }
        .padding(16)
        // 右栏再窄也不能把输入区压成只剩一条提示：高度由内容决定，
        // 剩余高度只分给下面的控制台。
        .fixedSize(horizontal: false, vertical: true)
    }

    private var environmentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("环境变量")
                .font(.headline)
            Text("每行一条 KEY=VALUE；支持 # 注释、export 前缀与 ${VAR} 展开。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: environmentBinding)
                .scrollContentBackground(.hidden)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 360, height: 150)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
            HStack {
                Button("清空") {
                    updateSettings { $0.environmentText = "" }
                }
                .disabled(settings.environmentText.isEmpty)
                Spacer()
                Button("完成") {
                    showEnvironment = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func statusBadge(_ model: RunningProcessModel) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateColor(model.state))
                .frame(width: 7, height: 7)
            Text(model.state.displayText)
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor(model.state))
            if !model.listeningPorts.isEmpty {
                Text(model.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stateColor(_ state: ProcessState) -> Color {
        switch state {
        case .running: return .green
        case .preparing, .building, .resolvingClasspath, .starting: return .orange
        case .stopping: return .yellow
        case .failed: return .red
        case .exited, .cancelled: return .secondary
        }
    }

    // MARK: - 控制台

    @ViewBuilder
    private var console: some View {
        if let model = displayModel {
            LogConsoleView(model: model)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("输入命令并点「运行」，输出会显示在这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 表单状态与持久化

    private var commandBinding: Binding<String> {
        Binding(
            get: { settings.command },
            set: { value in updateSettings { $0.command = value } }
        )
    }

    private var workingDirectoryBinding: Binding<String> {
        Binding(
            get: { settings.workingDirectory },
            set: { value in updateSettings { $0.workingDirectory = value } }
        )
    }

    private var environmentBinding: Binding<String> {
        Binding(
            get: { settings.environmentText },
            set: { value in updateSettings { $0.environmentText = value } }
        )
    }

    /// 先改本地副本再整体写回：每个击键都持久化，但不会经 AppStore 触发全界面重绘。
    private func updateSettings(_ mutate: (inout CommandLineSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        settings = updated
        store.updateCommandLineSettings(updated, projectID: project.id)
    }

    private var restartDisabled: Bool {
        guard let active = activeModel else { return !settings.isRunnable }
        return !active.isRunning
    }

    private func run() {
        guard canRun else { return }
        store.runCommandLine(projectID: project.id)
    }
}
