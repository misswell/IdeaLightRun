import SwiftUI
import AppKit
import IdeaLightRunCore

/// §66: 退出时默认 Stop services and quit。
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        AppStore.shared.stopActiveWork()
        return .terminateNow
    }

    /// 在线更新移交后的退出：走一次正常的 terminate，让 §66 的收尾照常在
    /// `applicationShouldTerminate` 里跑；但它可能被静默吞掉（见
    /// `SoftwareUpdater.quitAfterHandoff`），而更新助手只等本进程 60s，
    /// 超时就不替换了。所以 terminate 一旦返回，自己收尾后强制退——
    /// 不允许留下「助手在等、进程却活着」的僵死状态。
    @MainActor static func terminateForInstallation() {
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

                        Button {
                            NSWorkspace.shared.open(project.url)
                        } label: {
                            Image(systemName: "folder.badge.gearshape")
                        }
                        .help("在 Finder 中显示项目")

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

    private func header(project: ProjectEntry) -> some View {
        HStack(spacing: 10) {
            if let config = store.selectedConfiguration {
                configActions(config: config)
            } else {
                Text(project.name)
                    .font(.title3.weight(.semibold))
            }

            Spacer()

            Picker("", selection: $detailTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
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
            Text(config.name)
                .font(.title3.weight(.semibold))
            Text(config.type.displayName)
                .foregroundStyle(.secondary)

            Spacer()

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
        // 撑满顶栏剩余宽度，让内部 Spacer 把按钮推到右侧（标签页选择器在其右）
        .frame(maxWidth: .infinity)
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

struct LogConsoleView: NSViewRepresentable {
    @ObservedObject var model: LogViewModel

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        if coordinator.generation != model.clearGeneration {
            coordinator.generation = model.clearGeneration
            coordinator.nextAbsolute = 0
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        }

        // 增量渲染：用绝对行号对齐（model.lines 有环形截断，firstLineIndex 会前移）
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
            for line in newLines {
                attributed.append(Self.attributed(line))
            }
            if let storage = textView.textStorage {
                storage.append(attributed)
                // TextStorage 自身也设上限，防止无限膨胀
                let maxCharacters = 2_000_000
                if storage.length > maxCharacters {
                    storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxCharacters))
                }
            }
            textView.needsDisplay = true
            if coordinator.follow {
                textView.scrollToEndOfDocument(nil)
            }
        }
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

    final class Coordinator {
        var nextAbsolute = 0
        var generation = 0
        var follow = true
    }
}
