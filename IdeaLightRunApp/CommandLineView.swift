import AppKit
import IdeaLightRunCore
import SwiftUI

/// 右侧「命令行」页签：项目级、手写命令。
/// 不走 IDEA Run Configuration，也不要求项目是 Java / Maven / Gradle；
/// 执行与日志仍然复用 Core 的统一进程管线。
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
            Divider()
            console
        }
        .task(id: project.id) {
            settings = store.commandLineSettings(forProject: project.id)
            showEnvironment = !settings.environmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    // MARK: - 命令表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("命令", systemImage: "terminal")
                    .font(.callout.weight(.medium))
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

            HStack(spacing: 8) {
                TextField("例如 npm run dev、python3 app.py、./scripts/dev.sh", text: commandBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(run)
                    .help("按回车运行。命令通过登录 zsh 执行，支持管道、&&、变量与别名。")
                Button(action: run) {
                    Label("运行", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canRun)
                .help(canRun ? "在项目目录启动这条命令（⌘R）" : "先输入命令，或等待当前命令结束")
            }

            HStack(spacing: 8) {
                Text("工作目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                TextField(project.url.path, text: workingDirectoryBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .help("留空使用项目根目录；支持 ~、$PROJECT_DIR$ 与相对路径")
                Button {
                    showDirectoryPicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("选择工作目录")
                if !settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("项目根") {
                        updateSettings { $0.workingDirectory = "" }
                    }
                    .help("恢复为项目根目录")
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

                Spacer(minLength: 0)
            }
            .controlSize(.small)

            DisclosureGroup(isExpanded: $showEnvironment) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: environmentBinding)
                        .scrollContentBackground(.hidden)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 64, maxHeight: 96)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                    Text("每行一条 KEY=VALUE；支持 # 注释、export 前缀与 ${VAR} 展开。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text("环境变量")
                    if !settings.environmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("已设置")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("命令在登录 zsh 中后台执行，可使用管道、&&、变量和别名；"
                + "需要终端输入的命令（如 sudo、交互式登录）请在 Terminal 中运行。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
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
