import SwiftUI
import AppKit
import IdeaLightRunCore

/// §66: 退出时默认 Stop services and quit。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 更新移交触发的退出：更新面板里已说明会停掉服务，`applicationShouldTerminate`
    /// 不再弹退出确认，直接走 §66 收尾。
    static var isTerminatingForInstallation = false

    /// 关掉最后一个窗口后进程仍然活着（窗口只是没了，App 没退），此时点 Dock 图标
    /// 默认只做「激活」，SwiftUI 不会重建窗口——看上去就是「点了没反应」。
    /// 这里补上：没有可见窗口时走 SwiftUI 自己注册的 New Window 菜单项，
    /// 和按 ⌘N 完全同一条路径，因此带回来的窗口状态与手动新开的一致。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        sender.activate(ignoringOtherApps: true)
        // 窗口只是被最小化：交给 AppKit 恢复原窗口，另开一个等于凭空多一份界面
        if sender.windows.contains(where: { $0.isMiniaturized }) { return true }
        return performNewWindowCommand(sender) ? false : true
    }

    private func performNewWindowCommand(_ sender: NSApplication) -> Bool {
        for top in sender.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            for (index, item) in submenu.items.enumerated() {
                guard item.action != nil,
                      item.keyEquivalent == "n",
                      item.keyEquivalentModifierMask.contains(.command) else { continue }
                submenu.performActionForItem(at: index)
                return true
            }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isTerminatingForInstallation {
            AppStore.shared.stopActiveWork()
            return .terminateNow
        }
        let services = AppStore.shared.activeSessionCount
        let builds = AppStore.shared.activeBuildCount
        guard services > 0 || builds > 0 else {
            return .terminateNow
        }
        return Self.confirmTerminate(services: services, builds: builds)
    }

    /// 有任务在跑时的退出确认。runModal 同步拿结果，不需要 terminateLater/reply 簿记。
    /// 更新移交路径不进这里：面板里已说明会停服务，而且更新助手只等本进程 60s。
    @MainActor
    private static func confirmTerminate(services: Int, builds: Int) -> NSApplication.TerminateReply {
        var subjects: [String] = []
        if services > 0 { subjects.append("\(services) 个运行中的服务") }
        if builds > 0 { subjects.append("\(builds) 个进行中的构建") }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出前还有任务未结束"
        alert.informativeText = "当前有 \(subjects.joined(separator: "、"))，退出会一并结束这些子进程。"
            + "「停止并退出」先正常终止（SIGTERM），最多等 2 秒再强制结束；「强制结束」立即杀掉，可能丢失未落盘的输出。"
        alert.addButton(withTitle: "停止并退出")
        alert.addButton(withTitle: "强制结束")
        alert.addButton(withTitle: "取消")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppStore.shared.stopActiveWork()
            return .terminateNow
        case .alertSecondButtonReturn:
            AppStore.shared.forceKillAllWork()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// 在线更新移交后的退出：走一次正常的 terminate，让 §66 的收尾照常在
    /// `applicationShouldTerminate` 里跑；但它可能被静默吞掉（见
    /// `SoftwareUpdater.quitAfterHandoff`），而更新助手只等本进程 60s，
    /// 超时就不替换了。所以 terminate 一旦返回，自己收尾后强制退——
    /// 不允许留下「助手在等、进程却活着」的僵死状态。
    @MainActor static func terminateForInstallation() {
        isTerminatingForInstallation = true
        NSApp.terminate(nil)
        AppStore.shared.stopActiveWork()
        exit(0)
    }
}

@main
struct IdeaLightRunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("IdeaLightRun") {
            RootView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            BuildCommands()
            UpdateCommands()
        }
    }
}

/// IDEA 的 Build 菜单：Build Project（⌘F9）/ Rebuild Project（⇧⌘F9）+ Maven clean。
/// 菜单项不做置灰——不可用时点了要给原因（弹窗），而不是让人猜为什么不能点。
struct BuildCommands: Commands {
    /// AppKit 用私有码点表示功能键：F9 = 0xF70C。
    private static let f9 = KeyEquivalent(Character(UnicodeScalar(0xF70C)!))

    var body: some Commands {
        CommandMenu("构建") {
            Button("构建项目") { AppStore.fromMenu { $0.build(kind: .build) } }
                .keyboardShortcut(Self.f9, modifiers: .command)
            Button("重新构建项目") { AppStore.fromMenu { $0.build(kind: .rebuild) } }
                .keyboardShortcut(Self.f9, modifiers: [.command, .shift])
            Button("清理项目") { AppStore.fromMenu { $0.build(kind: .clean) } }
            Divider()
            Button("停止构建") { AppStore.fromMenu { $0.stopBuild() } }
            Button("强制结束构建") { AppStore.fromMenu { $0.forceKillBuild() } }
        }
    }
}

struct RootView: View {
    @ObservedObject private var store = AppStore.shared
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, showImporter: $showImporter)
        } content: {
            ConfigurationListView(store: store)
        } detail: {
            ConfigurationDetailView(store: store)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.addProject(url: url)
            }
        }
        .alert(
            "IdeaLightRun",
            isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { store.updater.isPresented },
                set: { store.updater.isPresented = $0 }
            ),
            onDismiss: { store.updater.updateSheetDidDismiss() }
        ) {
            UpdateSheet(updater: store.updater, activeSessionCount: store.activeSessionCount)
        }
    }
}

// MARK: - 侧栏：项目列表（§50 第一栏）

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Binding var showImporter: Bool

    var body: some View {
        List(selection: $store.selectedProjectID) {
            Section("项目") {
                ForEach(store.projects) { project in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .lineLimit(1)
                            subtitle(for: project)
                        }
                    }
                    .tag(project.id)
                    .contextMenu {
                        Button("构建项目") { store.build(projectID: project.id, kind: .build) }
                            .disabled(project.result?.buildSystem.maven == nil)
                        Button("重新构建项目") { store.build(projectID: project.id, kind: .rebuild) }
                            .disabled(project.result?.buildSystem.maven == nil)
                        Button("清理项目") { store.build(projectID: project.id, kind: .clean) }
                            .disabled(project.result?.buildSystem.maven == nil)
                        if store.builds[project.id]?.phase.isBusy == true {
                            Button("停止构建", role: .destructive) { store.stopBuild(projectID: project.id) }
                        }
                        Divider()
                        Button("重新扫描") { store.rescan(entryID: project.id) }
                        Divider()
                        Button("移除", role: .destructive) { store.removeProject(id: project.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    showImporter = true
                } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
        .overlay {
            if store.projects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("拖入项目文件夹，或点击下方“添加项目”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.addProject(url: url)
            return true
        }
    }

    @ViewBuilder
    private func subtitle(for project: ProjectEntry) -> some View {
        if project.isScanning {
            Text("扫描中…").font(.caption2)
        } else if let count = project.result?.configurations.count {
            Text("\(count) 个配置").font(.caption2)
        } else if project.errorText != nil {
            Text("扫描失败").font(.caption2).foregroundStyle(.red)
        } else {
            Text("待扫描").font(.caption2)
        }
    }
}

// MARK: - 中栏：配置列表（§50/§51）

struct ConfigurationListView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Group {
            if let project = store.selectedProject {
                VStack(spacing: 0) {
                    ProjectSummaryView(store: store, project: project)
                    Divider()
                    configList(project: project)
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            store.rescan(entryID: project.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("重新扫描")
                        .disabled(project.isScanning)

                        OpenWithMenu(projectURL: project.url)

                        Button(role: .destructive) {
                            store.removeProject(id: project.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("移除项目")
                    }
                }
            } else {
                Text("选择一个项目")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func configList(project: ProjectEntry) -> some View {
        if let result = project.result {
            if result.configurations.isEmpty {
                emptyState(icon: "tray", text: "未发现 Run Configuration")
            } else {
                List(selection: $store.selectedConfigurationKey) {
                    ForEach(result.configurations) { config in
                        ConfigurationRow(
                            config: config,
                            runtimeState: store.sessions[config.uniqueKey]?.state
                        )
                        .tag(config.uniqueKey)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { keys in
                    if let key = keys.first {
                        // 可用性跟随运行态，避免点了没反应的菜单项
                        let model = store.sessions[key]
                        Button("运行 ▶") { store.run(configKey: key) }
                            .disabled(model.map { !$0.state.isTerminal } ?? false)
                        Button("重启 ↻") { store.restart(configKey: key) }
                            .disabled(model.map { $0.isBuilding || $0.state == .stopping } ?? false)
                        Button("停止 ■", role: .destructive) { store.stop(configKey: key) }
                            .disabled(model.map { !$0.state.isActive || $0.state == .stopping } ?? true)
                    }
                } primaryAction: { keys in
                    if let key = keys.first {
                        store.selectedConfigurationKey = key
                    }
                }
            }
        } else if project.isScanning {
            VStack(spacing: 10) {
                ProgressView()
                Text("扫描中…").foregroundStyle(.secondary)
            }
        } else if let error = project.errorText {
            emptyState(icon: "exclamationmark.triangle", text: error)
        } else {
            emptyState(icon: "tray", text: "待扫描")
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProjectSummaryView: View {
    @ObservedObject var store: AppStore
    let project: ProjectEntry

    var body: some View {
        HStack(spacing: 14) {
            chip(icon: "wrench.and.screwdriver", text: buildSystemText)
            if let jdk = project.projectJDK?.installation {
                chip(icon: "cpu", text: "JDK \(jdk.majorVersion.map(String.init) ?? "?") · \(jdk.displayName ?? jdk.home.lastPathComponent)")
            }
            if let result = project.result {
                chip(icon: "square.stack.3d.up", text: "\(result.modules.count) 模块")
            }
            // .id 让切换项目时重建模型，重新读新项目的分支
            GitControls(project: project)
                .id(project.id)
            Spacer()
            buildControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// IDEA 的 Build Project / Rebuild Project 与 Maven clean：项目级、作用于整个 reactor。
    private var buildControls: some View {
        let build = store.builds[project.id]
        let busy = build?.phase.isBusy ?? false
        let mavenReady = project.result?.buildSystem.maven != nil
        let unavailableHint = "仅支持 Maven 项目；Gradle 支持在 Milestone 4 提供"

        return HStack(spacing: 8) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                Text(build?.statusText ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("停止构建") { store.stopBuild(projectID: project.id) }
                    .disabled(build?.phase == .stopping)
                    .help("终止 Maven 进程（SIGTERM）")
                if build?.phase == .stopping {
                    Button(role: .destructive) {
                        store.forceKillBuild(projectID: project.id)
                    } label: {
                        Image(systemName: "xmark.octagon.fill")
                    }
                    .help("强制结束（SIGKILL）")
                }
            } else {
                Button("构建") { store.build(projectID: project.id, kind: .build) }
                    .disabled(!mavenReady)
                    .help(mavenReady ? "增量编译整个项目（IDEA 的 Build Project，⌘F9）" : unavailableHint)
                Button("重新构建") { store.build(projectID: project.id, kind: .rebuild) }
                    .disabled(!mavenReady)
                    .help(mavenReady ? "清空产物后全量编译（IDEA 的 Rebuild Project，⇧⌘F9）" : unavailableHint)
                Button("清理") { store.build(projectID: project.id, kind: .clean) }
                    .disabled(!mavenReady)
                    .help(mavenReady ? "只清空各模块 target/ 产物，不编译（Maven clean）" : unavailableHint)
            }
        }
        .controlSize(.small)
    }

    private var buildSystemText: String {
        guard let result = project.result else { return "…" }
        var parts: [String] = []
        if result.buildSystem.maven != nil { parts.append("Maven") }
        if result.buildSystem.gradle != nil { parts.append("Gradle") }
        return parts.isEmpty ? "未知构建系统" : parts.joined(separator: " + ")
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .lineLimit(1)
        }
    }
}

struct ConfigurationRow: View {
    let config: RunConfiguration
    let runtimeState: ProcessState?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        var parts: [String] = [config.type.displayName]
        if let mainClass = config.mainClass {
            parts.append(mainClass)
        } else if !config.compoundMembers.isEmpty {
            parts.append(config.compoundMembers.map(\.name).joined(separator: ", "))
        }
        if !config.springProfiles.isEmpty {
            parts.append(config.springProfiles.joined(separator: ","))
        }
        return parts.joined(separator: " · ")
    }

    private var statusLabel: String {
        if let runtimeState {
            return runtimeState.displayText
        }
        switch config.readiness {
        case .ready: return "READY"
        case .warning: return "WARNING"
        case .planned: return "PLANNED"
        case .unsupported: return "UNSUPPORTED"
        }
    }

    /// §51: 状态颜色克制。
    private var statusColor: Color {
        if let runtimeState {
            switch runtimeState {
            case .running: return .green
            case .building, .resolvingClasspath, .preparing, .starting: return .orange
            case .stopping: return .yellow
            case .failed: return .red
            case .exited, .cancelled: return .secondary
            }
        }
        switch config.readiness {
        case .ready: return .green
        case .warning: return .orange
        case .planned: return .blue
        case .unsupported: return .secondary
        }
    }
}

// MARK: - 右栏：详情 + 运行操作 + 控制台

struct ConfigurationDetailView: View {
    @ObservedObject var store: AppStore
    @State private var revealSecrets = false
    @State private var resolvedJDK: JDKResolution?
    @State private var resolvedModuleDirectory: URL?
    @State private var resolvedWorkDir: String?
    @State private var detailTab: DetailTab = .info

    enum DetailTab: String, CaseIterable {
        case info = "信息"
        case console = "控制台"
        case build = "构建"
    }

    var body: some View {
        Group {
            if let project = store.selectedProject {
                VStack(spacing: 0) {
                    header(project: project)
                    Divider()
                    detailContent(project: project)
                }
                .task(id: store.selectedConfiguration?.uniqueKey) {
                    revealSecrets = false
                    if let config = store.selectedConfiguration, let result = project.result {
                        await resolveDetails(config: config, result: result)
                    }
                }
                // 开始构建后自动切到构建页，对齐 IDEA 弹出 Build 窗口的行为
                .onChange(of: store.buildRevision) { _ in detailTab = .build }
            } else {
                emptyPane(icon: "doc.text.magnifyingglass", text: "选择一个项目查看配置")
            }
        }
    }

    @ViewBuilder
    private func detailContent(project: ProjectEntry) -> some View {
        switch detailTab {
        case .info:
            if let config = store.selectedConfiguration, let result = project.result {
                infoDetail(config: config, result: result)
            } else {
                emptyPane(icon: "doc.text.magnifyingglass", text: "选择一个配置查看详情")
            }
        case .console:
            if let config = store.selectedConfiguration, let model = store.sessions[config.uniqueKey] {
                LogConsoleView(model: model)
            } else {
                emptyPane(icon: "terminal", text: "尚未启动，无运行日志")
            }
        case .build:
            buildDetail(project: project)
        }
    }

    private func emptyPane(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 构建页（IDEA 的 Build 窗口）

    private func buildDetail(project: ProjectEntry) -> some View {
        Group {
            if let model = store.builds[project.id] {
                VStack(alignment: .leading, spacing: 0) {
                    buildBanner(model: model, project: project)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider()
                    LogConsoleView(model: model)
                }
            } else {
                emptyPane(
                    icon: "hammer",
                    text: "尚未构建。用 ⌘F9 构建项目，或点项目摘要里的「构建」"
                )
            }
        }
    }

    private func buildBanner(model: ProjectBuildModel, project: ProjectEntry) -> some View {
        HStack(spacing: 10) {
            if model.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.statusText)
                .font(.callout.weight(.medium))
            Text(project.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("清空日志") { model.clearLogs() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 顶栏：操作按钮（§52）

    /// 顶栏分两行：标题独占一行，操作按钮与标签页在第二行。
    /// 挤成一行时窄窗口会把标题压成竖排（`TgTenantApplication (1)` 每字一行）。
    private func header(project: ProjectEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let config = store.selectedConfiguration {
                    Text(config.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(config.name)
                    Text(config.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(project.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                if let config = store.selectedConfiguration {
                    configActions(config: config)
                }
                Spacer(minLength: 8)
                Picker("", selection: $detailTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func configActions(config: RunConfiguration) -> some View {
        let model = store.sessions[config.uniqueKey]
        // §23: 只读 Core 声明的类型支持级别，不在这里判断构建系统——
        // 缺 Maven / 不支持的类型由 Core 在点击时给出明确错误。
        let launchable = config.type.supportLevel == .supported
        // IDEA 行为：构建期与运行期 Stop 都可用
        let stopEnabled = model?.state.isActive == true && model?.state != .stopping

        HStack(spacing: 10) {
            Button {
                store.run(configKey: config.uniqueKey)
                detailTab = .console
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(launchable ? "编译并启动" : "IdeaLightRun 暂不能启动这类配置")
            .disabled(!launchable || model != nil && !model!.state.isTerminal)

            Button {
                store.stop(configKey: config.uniqueKey)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .keyboardShortcut(".", modifiers: .command)
            .help(model?.isActiveBuildPhase == true ? "终止 Maven 构建" : "发送 SIGTERM")
            .disabled(!stopEnabled)

            if model?.state == .stopping {
                Button(role: .destructive) {
                    store.forceKill(configKey: config.uniqueKey)
                } label: {
                    Label("Force Kill", systemImage: "xmark.octagon.fill")
                }
                .help("强制结束（SIGKILL）")
            }

            Button {
                store.restart(configKey: config.uniqueKey)
                detailTab = .console
            } label: {
                Label("Restart", systemImage: "arrow.triangle.2.circlepath")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("停止旧进程后重新编译启动")
            .disabled(model == nil || model?.isBuilding == true)
            .disabled(model?.state == .stopping)
        }
        // 不撑满宽度：按钮组左对齐，右侧留给标签页选择器（见 `header`）。
        .fixedSize()
    }

    // MARK: 信息页

    private func infoDetail(config: RunConfiguration, result: ScanResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let model = store.sessions[config.uniqueKey] {
                    runtimeBanner(model: model)
                }

                section("运行信息") {
                    keyRow("Main Class", config.mainClass, monospaced: true)
                    keyRow("Module", config.moduleName)
                    if let directory = resolvedModuleDirectory {
                        keyRow("Module 目录", directory.path, monospaced: true)
                    }
                    keyRow("JDK", jdkText)
                    keyRow("VM Options", config.vmOptions, monospaced: true)
                    keyRow("Program Arguments", config.programArguments, monospaced: true)
                    if !config.springProfiles.isEmpty {
                        keyRow("Spring Profiles", config.springProfiles.joined(separator: ", "))
                    }
                    keyRow("Working Directory", resolvedWorkDir ?? config.workingDirectory, monospaced: true)
                }

                if !config.compoundMembers.isEmpty {
                    section("Compound 成员") {
                        ForEach(config.compoundMembers, id: \.self) { member in
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.stack")
                                    .foregroundStyle(.secondary)
                                Text(member.name)
                            }
                        }
                    }
                }

                if !config.environmentVariables.isEmpty {
                    section("环境变量") {
                        HStack {
                            Text("默认隐藏取值（§28）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle("显示明文", isOn: $revealSecrets)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                        ForEach(config.environmentVariables.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text(key)
                                    .font(.system(.callout, design: .monospaced))
                                    .frame(width: 200, alignment: .leading)
                                Text(revealSecrets ? (config.environmentVariables[key] ?? "") : "••••••••")
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !config.beforeLaunchTasks.isEmpty {
                    section("Before Launch") {
                        ForEach(config.beforeLaunchTasks, id: \.self) { task in
                            HStack(spacing: 6) {
                                Image(systemName: task.isEnabled ? "checkmark.circle" : "minus.circle")
                                    .foregroundStyle(.secondary)
                                Text(task.displayName)
                            }
                        }
                    }
                }

                if !config.warnings.isEmpty {
                    section("警告") {
                        ForEach(config.warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.yellow)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(warning.title).fontWeight(.medium)
                                    Text(warning.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                section("来源") {
                    keyRow("配置来源", config.source.kind.displayName)
                    keyRow("文件", config.source.file.path, monospaced: true)
                    if let modified = config.source.modifiedAt {
                        keyRow("修改时间", modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runtimeBanner(model: RunningProcessModel) -> some View {
        HStack(spacing: 10) {
            if model.isBuilding {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.state.displayText)
                .font(.callout.weight(.medium))
            if let pid = model.pid {
                Text("PID \(pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.listeningPorts.isEmpty {
                Text("端口 \(model.listeningPorts.map(String.init).joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("本机 lsof 探测到的 LISTEN TCP 端口")
            }
            Spacer()
            Button("清空日志") {
                model.clearLogs()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var jdkText: String? {
        guard let jdk = resolvedJDK else { return nil }
        guard let installation = jdk.installation else {
            return jdk.warnings.first?.detail
        }
        let version = installation.majorVersion.map(String.init) ?? "?"
        let origin: String
        switch jdk.origin {
        case .runConfigurationSpecified: origin = "Run Configuration 指定"
        case .projectSDK: origin = "IDEA 项目 SDK"
        case .javaHome: origin = "JAVA_HOME"
        case .systemInstalled: origin = "系统默认"
        case .notResolved: origin = "未解析"
        }
        return "\(installation.displayName ?? installation.home.lastPathComponent) (major \(version)) — \(origin)"
    }

    /// §100: JDK/宏/模块解析不进主线程。
    private func resolveDetails(config: RunConfiguration, result: ScanResult) async {
        resolvedJDK = nil
        resolvedModuleDirectory = nil
        resolvedWorkDir = nil

        let configJDKName = config.jreReference
        let projectJDKName = result.projectJDKName
        let moduleName = config.moduleName
        let mainClass = config.mainClass
        let projectRoot = result.projectRoot
        let knownModules = result.modules
        let rawWorkDir = config.workingDirectory

        let (jdk, moduleDir, workDir) = await Task.detached(priority: .userInitiated) { () -> (JDKResolution, URL?, String?) in
            let resolution = ModuleResolver.resolveModule(
                named: moduleName,
                mainClass: mainClass,
                projectRoot: projectRoot,
                knownModules: knownModules
            )
            let jdk = JDKResolver().resolve(configJDKName: configJDKName, projectJDKName: projectJDKName)
            let workDir = rawWorkDir.map {
                MacroResolver(projectDir: projectRoot, moduleDir: resolution.module?.directory).resolve($0).value
            }
            return (jdk, resolution.module?.directory, workDir)
        }.value

        resolvedJDK = jdk
        resolvedModuleDirectory = moduleDir
        resolvedWorkDir = workDir
    }

    // MARK: - 布局小件

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func keyRow(_ title: String, _ value: String?, monospaced: Bool = false) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .trailing)
                Text(value)
                    .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - 控制台（§38: NSTextView，不用 SwiftUI List 渲染日志）

/// 控制台 = 查找条（搜索高亮 + 行筛选）+ NSTextView。运行会话与项目构建共用。
/// 搜索与筛选语义不同：搜索只高亮、可在匹配间跳转，不改显示的行；
/// 筛选把未命中的行从显示里过滤掉。
struct LogConsoleView: View {
    @ObservedObject var model: LogViewModel
    @State private var searchDraft = ""
    @State private var filterDraft = ""
    @State private var searchCommitTask: Task<Void, Never>?
    @State private var filterCommitTask: Task<Void, Never>?
    /// 自动换行偏好：全局共享并跨启动记忆，默认不换行（长行横向滚动查看）。
    @AppStorage("consoleWrapText") private var wrapText = false

    /// 匹配总次数：按缓冲里的行统计；高亮与跳转在 NSTextView 侧按已渲染内容算。
    private var searchMatchCount: Int {
        LogTextView.matchCount(of: model.searchText, in: model.lines)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            Divider()
            LogTextView(model: model, wrapText: wrapText)
        }
        .onAppear {
            searchDraft = model.searchText
            filterDraft = model.displayFilter.filterText
        }
        .onChange(of: searchDraft) { newValue in
            // 每敲一个字就全量重扫一遍太重（缓冲上限 2 万行），稍微攒一下再提交
            searchCommitTask?.cancel()
            searchCommitTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                model.searchCurrentIndex = 0
                model.searchText = newValue
            }
        }
        .onChange(of: filterDraft) { newValue in
            filterCommitTask?.cancel()
            filterCommitTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                model.displayFilter.filterText = newValue
            }
        }
        .onChange(of: searchMatchCount) { newCount in
            // 匹配数变少后索引可能越界
            if model.searchCurrentIndex >= max(newCount, 1) {
                model.searchCurrentIndex = max(newCount - 1, 0)
            }
        }
    }

    /// 工具条分两行：第一行搜索与跳转，第二行筛选与显示选项。
    /// 挤成一行时窄窗口会把两个输入框都截成「筛选：过滤…」。
    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                searchField
                navigationControls
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                filterField
                streamPicker
                Toggle("换行", isOn: $wrapText)
                    .toggleStyle(.checkbox)
                    .help("开启后长行自动折行；默认关闭，长行横向滚动查看")
                if model.displayFilter.isActive {
                    Text("\(model.visibleLineCount) / \(model.lines.count) 行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索（只高亮）", text: $searchDraft)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchDraft.isEmpty {
                Button {
                    searchCommitTask?.cancel()
                    searchDraft = ""
                    model.searchCurrentIndex = 0
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(minWidth: 120, maxWidth: 260)
        .help("高亮匹配内容，不改变显示的行")
    }

    @ViewBuilder
    private var navigationControls: some View {
        let count = searchMatchCount
        HStack(spacing: 2) {
            Button {
                stepMatch(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(count == 0)
            .help("上一个匹配")
            Button {
                stepMatch(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(count == 0)
            .help("下一个匹配")
        }
        if !model.searchText.isEmpty {
            Text(count == 0 ? "0/0" : "\(model.searchCurrentIndex + 1)/\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(count == 0 ? "无匹配" : "当前匹配 / 匹配总数")
        }
    }

    private func stepMatch(_ delta: Int) {
        let count = searchMatchCount
        guard count > 0 else { return }
        model.searchCurrentIndex = (model.searchCurrentIndex + delta + count) % count
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("筛选：过滤掉未匹配的行", text: $filterDraft)
                .textFieldStyle(.plain)
                .font(.callout)
            if !filterDraft.isEmpty {
                Button {
                    filterCommitTask?.cancel()
                    filterDraft = ""
                    model.displayFilter.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除筛选")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(minWidth: 120, maxWidth: 260)
        .help("只显示包含关键词的行（可与来源筛选叠加）")
    }

    private var streamPicker: some View {
        Picker("筛选", selection: $model.displayFilter.stream) {
            ForEach(ConsoleStreamFilter.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 170)
        .help("按日志来源筛选")
    }
}

private struct LogTextView: NSViewRepresentable {
    @ObservedObject var model: LogViewModel
    var wrapText: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.wrap = wrapText
        Self.configureWrap(wrapText, textView: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        if coordinator.wrap != wrapText {
            coordinator.wrap = wrapText
            Self.configureWrap(wrapText, textView: textView, scrollView: scrollView)
        }
        let filter = model.displayFilter
        let searchChanged = coordinator.appliedSearchText != model.searchText

        if coordinator.generation != model.clearGeneration || coordinator.filter != filter {
            // 清空或筛选条件变化：从当前缓冲按筛选全量重渲染
            coordinator.generation = model.clearGeneration
            coordinator.filter = filter
            coordinator.nextAbsolute = model.firstLineIndex + model.lines.count
            let attributed = NSMutableAttributedString()
            for line in model.lines where filter.matches(line) {
                attributed.append(Self.attributed(line))
            }
            storage.setAttributedString(attributed)
            // 渲染内容整个换掉了，搜索高亮从头重扫
            coordinator.searchRanges = []
            coordinator.scannedLength = 0
            coordinator.appliedCurrentIndex = -1
            coordinator.needsHighlightScan = true
            textView.needsDisplay = true
            if coordinator.follow {
                let previousOrigin = scrollView.contentView.bounds.origin
                textView.scrollToEndOfDocument(nil)
                if !wrapText {
                    // 纵向跟到底；不换行时横向留在原地，不跳到最长行的末尾
                    scrollView.contentView.scroll(
                        to: NSPoint(x: previousOrigin.x, y: scrollView.contentView.bounds.origin.y)
                    )
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        } else {
            // 增量渲染：用绝对行号对齐（model.lines 有环形截断，firstLineIndex 会前移）。
            // 不匹配筛选的行只跳过渲染，绝对行号照常推进；筛选条件一变就走上面的全量重渲染。
            let firstAbsolute = model.firstLineIndex
            var startOffset = coordinator.nextAbsolute - firstAbsolute
            if startOffset < 0 {
                // 早期行已被截断丢弃，跳过
                coordinator.nextAbsolute = firstAbsolute
                startOffset = 0
            }
            if startOffset < model.lines.count {
                let newLines = model.lines[startOffset...]
                coordinator.nextAbsolute = firstAbsolute + model.lines.count

                let attributed = NSMutableAttributedString()
                for line in newLines where filter.matches(line) {
                    attributed.append(Self.attributed(line))
                }
                if attributed.length > 0 {
                    storage.append(attributed)
                    // TextStorage 自身也设上限，防止无限膨胀
                    let maxCharacters = 2_000_000
                    if storage.length > maxCharacters {
                        let deleted = storage.length - maxCharacters
                        storage.deleteCharacters(in: NSRange(location: 0, length: deleted))
                        coordinator.shiftRangesAfterDeletion(deleted)
                    }
                    coordinator.needsHighlightScan = true
                    textView.needsDisplay = true
                    if coordinator.follow {
                        let previousOrigin = scrollView.contentView.bounds.origin
                        textView.scrollToEndOfDocument(nil)
                        if !wrapText {
                            // 纵向跟到底；不换行时横向留在原地，不跳到最长行的末尾
                            scrollView.contentView.scroll(
                                to: NSPoint(x: previousOrigin.x, y: scrollView.contentView.bounds.origin.y)
                            )
                            scrollView.reflectScrolledClipView(scrollView.contentView)
                        }
                    }
                }
            }
        }

        // —— 搜索：只高亮 + 上一个/下一个，不动显示的行 ——
        if searchChanged {
            coordinator.recomputeAllHighlights(storage, needle: model.searchText, currentIndex: model.searchCurrentIndex)
        } else if coordinator.needsHighlightScan {
            coordinator.scanNewRanges(storage, currentIndex: model.searchCurrentIndex)
        }
        if coordinator.appliedCurrentIndex != model.searchCurrentIndex {
            coordinator.applyCurrentIndex(storage, index: model.searchCurrentIndex, textView: textView)
        }
    }

    /// 自动换行开关：换行时文本视图宽度跟随容器；不换行时容器宽度无限、
    /// 文本视图随内容横向生长，靠水平滚动条查看长行。
    private static func configureWrap(_ wrap: Bool, textView: NSTextView, scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = !wrap
        if wrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            // 把不换行时已经撑开的宽度收回来
            if scrollView.contentSize.width > 0 {
                textView.frame.size.width = scrollView.contentSize.width
            }
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.sizeToFit()
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }

    private static func attributed(_ line: LogLine) -> NSAttributedString {
        let color: NSColor
        switch line.stream {
        case .stdout: color = .textColor
        case .stderr: color = .systemRed
        case .system: color = .secondaryLabelColor
        }
        let timeText = line.timestamp.formatted(date: .omitted, time: .standard)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        return NSAttributedString(
            string: "\(timeText) \(line.text)\n",
            attributes: [
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    // MARK: 搜索匹配

    /// 统计关键词在所有缓冲行里的出现次数（忽略大小写）。
    static func matchCount(of needle: String, in lines: [LogLine]) -> Int {
        guard !needle.isEmpty else { return 0 }
        var total = 0
        for line in lines {
            total += occurrenceRanges(of: needle, in: line.text as NSString).count
        }
        return total
    }

    /// 关键词在指定区间内的全部出现位置（忽略大小写、互不重叠、按出现顺序）。
    static func occurrenceRanges(of needle: String, in haystack: NSString, range limit: NSRange? = nil) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        let domain = limit ?? NSRange(location: 0, length: haystack.length)
        var ranges: [NSRange] = []
        var location = domain.location
        let end = domain.location + domain.length
        while location < end {
            let found = haystack.range(
                of: needle,
                options: [.caseInsensitive],
                range: NSRange(location: location, length: end - location)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            location = found.location + found.length
        }
        return ranges
    }

    final class Coordinator {
        var nextAbsolute = 0
        var generation = 0
        var follow = true
        var filter = ConsoleFilter()
        var wrap = false

        // 搜索高亮状态：只作用于 NSTextView 已渲染的内容
        var searchRanges: [NSRange] = []
        var scannedLength = 0
        var appliedSearchText = ""
        var appliedCurrentIndex = -1
        var needsHighlightScan = false

        static let normalHighlight = NSColor.systemYellow.withAlphaComponent(0.4)
        static let currentHighlight = NSColor.systemOrange.withAlphaComponent(0.8)

        /// 搜索词变化：清掉全部旧高亮，从头重扫（输入有 200ms 防抖，可承受）。
        func recomputeAllHighlights(_ storage: NSTextStorage, needle: String, currentIndex: Int) {
            searchRanges = []
            scannedLength = 0
            appliedCurrentIndex = -1
            needsHighlightScan = false
            if storage.length > 0 {
                storage.beginEditing()
                storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
                storage.endEditing()
            }
            appliedSearchText = needle
            guard !needle.isEmpty else { return }
            scanNewRanges(storage, currentIndex: currentIndex)
        }

        /// 增量：只扫 [scannedLength, length) 的新增区域，把新命中追加到 searchRanges。
        func scanNewRanges(_ storage: NSTextStorage, currentIndex: Int) {
            let total = storage.length
            guard total > scannedLength else { return }
            let domain = NSRange(location: scannedLength, length: total - scannedLength)
            scannedLength = total
            guard !appliedSearchText.isEmpty else { return }
            let newRanges = LogTextView.occurrenceRanges(of: appliedSearchText, in: storage.string as NSString, range: domain)
            guard !newRanges.isEmpty else { return }
            let normal = Self.normalHighlight
            let current = Self.currentHighlight
            storage.beginEditing()
            for (offset, range) in newRanges.enumerated() {
                let index = searchRanges.count + offset
                storage.addAttribute(.backgroundColor, value: index == currentIndex ? current : normal, range: range)
            }
            storage.endEditing()
            searchRanges.append(contentsOf: newRanges)
            if currentIndex < searchRanges.count {
                appliedCurrentIndex = currentIndex
            }
        }

        /// 当前匹配切换：把旧「当前」染回普通色、新「当前」染色并滚动到它。
        func applyCurrentIndex(_ storage: NSTextStorage, index: Int, textView: NSTextView) {
            storage.beginEditing()
            if searchRanges.indices.contains(appliedCurrentIndex) {
                storage.addAttribute(.backgroundColor, value: Self.normalHighlight, range: searchRanges[appliedCurrentIndex])
            }
            if searchRanges.indices.contains(index) {
                let range = searchRanges[index]
                storage.addAttribute(.backgroundColor, value: Self.currentHighlight, range: range)
                textView.scrollRangeToVisible(range)
            }
            storage.endEditing()
            appliedCurrentIndex = index
        }

        /// 环形截断删掉头部字符后，所有命中位置整体前移。
        func shiftRangesAfterDeletion(_ deleted: Int) {
            guard !searchRanges.isEmpty else { return }
            searchRanges = searchRanges.compactMap { range in
                let end = range.location + range.length
                guard end > deleted else { return nil }
                let newLocation = max(range.location - deleted, 0)
                let newLength = end - deleted - newLocation
                return newLength > 0 ? NSRange(location: newLocation, length: newLength) : nil
            }
            appliedCurrentIndex = -1
        }
    }
}
