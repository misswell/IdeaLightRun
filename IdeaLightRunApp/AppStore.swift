import Combine
import Foundation
import IdeaLightRunCore

struct ProjectEntry: Identifiable, Equatable {
    let url: URL
    var result: ScanResult?
    var projectJDK: JDKResolution?
    var errorText: String?
    var isScanning: Bool

    var name: String { url.lastPathComponent }
    var id: String { url.standardizedFileURL.path }
}

/// §98: 用户数据用 Codable + JSON，存 ~/Library/Application Support/IdeaLightRun/。
/// 不写数据库，不修改用户项目目录。
@MainActor
final class AppStore: ObservableObject {
    /// 全应用共用一个 store：窗口可以被关掉再重开（Dock 图标唤回），
    /// 每个窗口各建一份的话，重开的那份看不到正在跑的会话，
    /// 既按不了 Stop，退出时 `applicationShouldTerminate` 也漏停子进程。
    static let shared = AppStore()

    @Published private(set) var projects: [ProjectEntry] = []
    @Published var selectedProjectID: String?
    @Published var selectedConfigurationKey: String?
    @Published var alertMessage: String?
    /// 待确认移除的项目。移除会停掉该项目正在跑的服务，属于不可逆操作：
    /// 顶栏垃圾桶与侧栏右键菜单都先置这里，由 RootView 统一弹确认，
    /// 不在各视图各写一份（避免两条入口行为不一致）。
    @Published var projectPendingRemoval: ProjectEntry?
    /// 运行会话（含构建阶段），键 = 项目 + 配置 + 实例（§P0-1）。
    /// 以前键只是 configKey，两个项目里的同名配置会互相覆盖会话。
    @Published private(set) var sessions: [RunSessionID: RunningProcessModel] = [:]
    /// projectID → 最近一次项目级构建（IDEA 的 Build / Rebuild Project）
    @Published private(set) var builds: [String: ProjectBuildModel] = [:]
    /// 每次开始构建自增，UI 据此切到"构建"页看输出
    @Published private(set) var buildRevision = 0
    /// 在线更新（§64 例外：仅用户主动点「检查更新…」时联网）
    let updater: SoftwareUpdater

    private static let persistenceURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IdeaLightRun/projects.json")

    private var cancellables: Set<AnyCancellable> = []

    init() {
        updater = SoftwareUpdater()
        // updater 是嵌套的 ObservableObject，不转发就不会有人重绘。
        updater.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        loadProjects()
    }

    var selectedProject: ProjectEntry? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedConfiguration: RunConfiguration? {
        guard let key = selectedConfigurationKey else { return nil }
        return selectedProject?.result?.configurations.first { $0.uniqueKey == key }
    }

    // MARK: - 会话查询（§P0-1）

    /// 某项目某配置的全部会话实例，最新在前。
    func sessionModels(projectID: String, configKey: String) -> [RunningProcessModel] {
        sessions.values
            .filter { $0.projectPath == projectID && $0.configKey == configKey }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// 仍在运行（未到终态）的实例。
    func activeSessions(projectID: String, configKey: String) -> [RunningProcessModel] {
        sessionModels(projectID: projectID, configKey: configKey).filter { !$0.state.isTerminal }
    }

    /// 界面单模型展示用：优先还在跑的实例，否则最近一次（含失败）。
    func displaySession(projectID: String, configKey: String) -> RunningProcessModel? {
        let models = sessionModels(projectID: projectID, configKey: configKey)
        return models.first { !$0.state.isTerminal } ?? models.first
    }

    /// 配置可运行性统一由 Core 计算（类型 + 构建系统 + 字段 + Before Launch），
    /// GUI 只消费结果，不再自己按类型判断。
    func capability(for config: RunConfiguration, projectID: String) -> ConfigurationCapability {
        guard let result = projects.first(where: { $0.id == projectID })?.result else {
            return ConfigurationCapabilityResolver.resolve(config)
        }
        return ConfigurationCapabilityResolver.resolve(config, scan: result)
    }

    /// 能否再启动一个实例：不并行运行的配置同一时刻只允许一个活跃实例（§P0-6）。
    func canLaunch(projectID: String, config: RunConfiguration) -> Bool {
        guard capability(for: config, projectID: projectID).isLaunchable else { return false }
        return config.allowParallelRun || activeSessions(projectID: projectID, configKey: config.uniqueKey).isEmpty
    }

    /// 侧栏标识：把该项目下所有配置会话与项目级构建汇总成一个颜色。
    /// 优先级 failed ＞ busy ＞ running —— 出事要盖过"还在跑"，
    /// 因为用户扫一眼左侧列表就是为了找需要处理的项。
    enum ProjectActivity: Equatable {
        case none
        case running
        case busy
        case failed

        var title: String? {
            switch self {
            case .none: return nil
            case .running: return "有服务正在运行"
            case .busy: return "正在编译或启动"
            case .failed: return "最近一次运行失败"
            }
        }
    }

    func activity(forProject projectID: String) -> ProjectActivity {
        var activity: ProjectActivity = .none
        for model in sessions.values where model.projectPath == projectID {
            switch model.state {
            case .failed:
                return .failed
            case .running:
                activity = .running
            case .exited, .cancelled:
                break
            default:
                // preparing / building / resolvingClasspath / starting / stopping
                if activity == .none { activity = .busy }
            }
        }
        if let build = builds[projectID] {
            switch build.phase {
            case .failed:
                return .failed
            case .running, .stopping:
                if activity == .none { activity = .busy }
            case .succeeded, .cancelled:
                break
            }
        }
        return activity
    }

    /// 当前项目的最近一次构建（菜单项"停止构建"用）
    var currentBuild: ProjectBuildModel? {
        selectedProjectID.flatMap { builds[$0] }
    }

    /// 仍在运行的服务数：更新面板据此说明「安装会把它们停掉」。
    var activeSessionCount: Int {
        sessions.values.filter { !$0.state.isTerminal }.count
    }

    /// 进行中的项目级构建数：退出确认弹窗用。
    var activeBuildCount: Int {
        builds.values.filter { $0.phase.isBusy }.count
    }

    /// §66: 退出前把本应用拉起的所有子进程停干净（先 Stop，等不动就强杀）。
    /// 只有 `applicationShouldTerminate` 一个调用方时它长在 delegate 里；
    /// 在线更新的退出路径会被 AppKit 的模态规则挡掉，需要一个不依赖 delegate 的
    /// 收尾入口，所以收在这里由两处共用。
    func stopActiveWork() {
        let active = sessions.values.filter { !$0.state.isTerminal }
        for model in active {
            model.buildHandle?.terminate()
            model.session?.stop()
        }
        // 项目级构建（Build/Rebuild Project）的 Maven 子进程同样要停，否则退出后留下孤儿 mvn
        let building = builds.values.filter { $0.phase.isBusy }
        for model in building {
            model.handle?.terminate()
        }
        // 这里阻塞了主线程，model.state 由 Task { @MainActor } 写入、永远不会更新；
        // 必须轮询后台线程直接维护的 ManagedProcessSession / Process 状态。
        func stillAlive(_ model: RunningProcessModel) -> Bool {
            if let session = model.session { return !session.state.isTerminal }
            return model.buildHandle?.hasLiveProcess ?? false
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !active.contains(where: stillAlive) && !building.contains(where: { $0.handle?.hasLiveProcess ?? false }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for model in active {
            if let session = model.session {
                if !session.state.isTerminal { session.forceKill() }
            } else {
                model.buildHandle?.forceKill()
            }
        }
        for model in building {
            model.handle?.forceKill()
        }
    }

    /// 「强制结束并退出」：跳过 SIGTERM 的宽限期，直接 SIGKILL 所有子进程。
    func forceKillAllWork() {
        for model in sessions.values where !model.state.isTerminal {
            model.session?.forceKill()
            model.buildHandle?.forceKill()
        }
        for model in builds.values where model.phase.isBusy {
            model.handle?.forceKill()
        }
    }

    /// 菜单命令的入口。`Commands.body` 在旧 SDK（CI 的 Xcode 15 / Swift 5.10）上不是
    /// `@MainActor`，闭包没法直接调主 actor 方法；显式走这里，两种工具链都成立。
    nonisolated static func fromMenu(_ action: @escaping @MainActor (AppStore) -> Void) {
        Task { @MainActor in
            action(shared)
        }
    }

    // MARK: - 运行管理（§32–§35）

    /// 启动一个新实例。
    /// - `allowParallelRun=false`（IDEA 默认）：该配置已有活跃实例时拒绝再次启动，
    ///   UI 的 ▶ 也会禁用；要换代码重启请用 Restart。
    /// - `allowParallelRun=true`：每次调用都创建新实例，各自拥有 PID / 日志 / 端口。
    func run(configKey: String, projectID: String? = nil) {
        let project = projectID.flatMap { id in projects.first { $0.id == id } } ?? selectedProject
        guard let project,
              let config = project.result?.configurations.first(where: { $0.uniqueKey == configKey }) else {
            return
        }
        // §23: 这里不再判断配置类型与构建系统——能不能跑由 Core 决定，
        // 跑不了的配置会以 unsupportedConfiguration 明确报出来。
        if !canLaunch(projectID: project.id, config: config) {
            return
        }
        // 新实例启动时清掉同配置的历史终态模型，字典不无界增长；
        // 活跃实例（并行运行时）不受影响。
        for (sessionID, model) in sessions
        where model.projectPath == project.id && model.configKey == configKey && model.state.isTerminal {
            sessions.removeValue(forKey: sessionID)
        }

        let sessionID = RunSessionID(projectID: project.id, configurationID: configKey)
        let model = RunningProcessModel(sessionID: sessionID, configName: config.name)
        model.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        // 重启可能发生在用户切换项目之后，必须锁定发起时的项目而不是当时的 selectedProject。
        model.onRestartNeeded = { [weak self] in
            self?.run(configKey: configKey, projectID: project.id)
        }
        sessions[sessionID] = model
        selectedConfigurationKey = configKey

        let projectRoot = project.url
        let coordinator = ExecutionCoordinator()
        let handle = ProcessHandle()
        model.buildHandle = handle
        Task.detached(priority: .userInitiated) {
            do {
                let plan = try await coordinator.prepare(
                    config: config,
                    projectRoot: projectRoot,
                    log: { line in
                        Task { @MainActor in model.appendLog(line) }
                    },
                    progress: { state in
                        Task { @MainActor in model.setPipelineState(state) }
                    },
                    processHandle: handle
                )
                // Stop 在构建期按下：终止构建，不再启动 Java（IDEA 行为）
                if handle.isCancelled {
                    await model.setPipelineState(.cancelled)
                    return
                }
                let session = try ManagedProcessSession(
                    configKey: configKey,
                    configName: config.name,
                    plan: plan,
                    logBuffer: model.logBuffer
                )
                await model.attach(session: session)
                // attach 与 start 之间的 Stop 由会话内部登记（stopRequested），
                // 进程跑起来后立即终止，不会漏停（§P0-3）。
                session.start()
            } catch let error as IdeaLightRunError {
                if case .launchCancelled = error {
                    await model.setPipelineState(.cancelled)
                } else {
                    await model.pipelineFailed(error.localizedDescription)
                    // §23: 类型 / 构建系统的判断搬进 Core 之后，「这个配置根本跑不了」
                    // 仍然要像以前一样弹窗，而不是只在控制台留一行小字。
                    switch error {
                    case .unsupportedConfiguration, .buildToolNotFound:
                        let message = error.localizedDescription
                        await MainActor.run { [weak self] in self?.alertMessage = message }
                    default:
                        break
                    }
                }
            } catch {
                await model.pipelineFailed(error.localizedDescription)
            }
        }
    }

    /// §33: 构建期 Stop → 终止 Maven 构建；运行期 Stop → SIGTERM 整棵进程树，
    /// 3 秒后仍有幸存者自动升级 SIGKILL。作用于该配置的全部活跃实例。
    func stop(configKey: String, projectID: String? = nil) {
        let id = projectID ?? selectedProjectID
        guard let id else { return }
        for model in activeSessions(projectID: id, configKey: configKey) {
            // model.state 经主线程异步投递，构建期/运行期的边界上可能仍是旧值；
            // 两个通道都发一次，避免 Stop 落空（已结束的句柄是 no-op）。
            model.buildHandle?.terminate()
            model.session?.stop()
        }
    }

    func forceKill(configKey: String, projectID: String? = nil) {
        let id = projectID ?? selectedProjectID
        guard let id else { return }
        for model in sessionModels(projectID: id, configKey: configKey) where !model.state.isTerminal {
            model.session?.forceKill()
            model.buildHandle?.forceKill()
        }
    }

    /// §34: 等旧实例退出后再重新走完整流水线。多实例时针对最新的活跃实例。
    func restart(configKey: String, projectID: String? = nil) {
        let id = projectID ?? selectedProjectID
        guard let id else { return }
        if let model = activeSessions(projectID: id, configKey: configKey).first {
            if model.isRunning {
                model.pendingRestart = true
                model.session?.stop()
            }
            // 构建期不允许重启（Stop 后可重新 Run）
            return
        }
        run(configKey: configKey, projectID: id)
    }

    // MARK: - 项目级构建（IDEA 的 Build / Rebuild Project）

    /// Build Project = 增量 `compile`；Rebuild Project = `clean compile` 全量；
    /// Clean = 只 `clean`（清空产物，不编译）。
    /// 构建中重复触发直接忽略：同项目已由 BuildGate 串行（§42），排队只会让 UI 看起来卡住。
    func build(projectID: String? = nil, kind: ProjectBuildKind) {
        guard let id = projectID ?? selectedProjectID,
              let project = projects.first(where: { $0.id == id }) else { return }
        guard project.result?.buildSystem.maven != nil else {
            alertMessage = "当前版本仅支持 Maven 项目\(kind.actionName)；Gradle 支持在 Milestone 4 提供。"
            return
        }
        guard builds[id]?.phase.isBusy != true else { return }

        let model = ProjectBuildModel(projectPath: id, kind: kind)
        let handle = ProcessHandle()
        model.handle = handle
        model.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        builds[id] = model
        buildRevision += 1

        let projectRoot = project.url
        let builder = ProjectBuilder()
        Task.detached(priority: .userInitiated) {
            do {
                try await builder.build(
                    projectRoot: projectRoot,
                    kind: kind,
                    log: { line in
                        Task { @MainActor in model.appendLog(line) }
                    },
                    processHandle: handle
                )
                await model.succeed()
            } catch let error as IdeaLightRunError {
                if case .launchCancelled = error {
                    await model.cancel()
                } else {
                    await model.fail(error.localizedDescription)
                }
            } catch {
                await model.fail(error.localizedDescription)
            }
        }
    }

    /// 停止构建 = SIGTERM Maven 进程（对齐 IDEA 的 Stop Build）；已结束的句子进程是 no-op。
    func stopBuild(projectID: String? = nil) {
        guard let id = projectID ?? selectedProjectID,
              let model = builds[id], model.phase.isBusy else { return }
        model.markStopping()
        model.handle?.terminate()
    }

    func forceKillBuild(projectID: String? = nil) {
        guard let id = projectID ?? selectedProjectID,
              let model = builds[id], model.phase.isBusy else { return }
        model.handle?.forceKill()
    }

    // MARK: - 项目管理（§48）

    func addProject(url: URL) {
        let standardized = url.standardizedFileURL
        guard BuildSystemDetector.isValidProjectRoot(standardized) else {
            alertMessage = "“\(standardized.lastPathComponent)” 不是有效的 Java 项目目录（需要包含 .idea、pom.xml 或 build.gradle(.kts) 之一）。"
            return
        }
        if projects.contains(where: { $0.id == standardized.path }) {
            selectedProjectID = standardized.path
            return
        }
        let entry = ProjectEntry(url: standardized, result: nil, projectJDK: nil, errorText: nil, isScanning: true)
        projects.append(entry)
        selectedProjectID = entry.id
        selectedConfigurationKey = nil
        persistProjects()
        rescan(entryID: entry.id)
    }

    /// §P0-5: 移除项目前必须先停干净该项目拉起的所有进程：
    /// Stop 全部会话与项目级构建 → 等待落终态 → 仍存活则强杀 → 确认后再删除。
    /// 绝不能出现"项目删了、后台进程还在跑"。
    func removeProject(id: String) {
        let owned = sessions.values.filter { $0.projectPath == id }
        for model in owned {
            model.buildHandle?.terminate()
            model.session?.stop()
        }
        builds[id]?.handle?.terminate()

        // model.state 由 Task { @MainActor } 异步投递，阻塞等待期间不会更新；
        // 与 stopActiveWork 一样轮询后台线程直接维护的会话状态。
        func allStopped() -> Bool {
            let sessionAlive = owned.contains { model in
                if let session = model.session { return !session.state.isTerminal }
                return model.buildHandle?.hasLiveProcess ?? false
            }
            let buildAlive = builds[id]?.handle?.hasLiveProcess ?? false
            return !sessionAlive && !buildAlive
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !allStopped() {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // 等不动的强杀
        for model in owned {
            if let session = model.session {
                if !session.state.isTerminal { session.forceKill() }
            } else {
                model.buildHandle?.forceKill()
            }
        }
        if builds[id]?.handle?.hasLiveProcess == true {
            builds[id]?.handle?.forceKill()
        }
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline, !allStopped() {
            Thread.sleep(forTimeInterval: 0.05)
        }

        for (sessionID, model) in sessions where model.projectPath == id {
            sessions.removeValue(forKey: sessionID)
        }
        builds.removeValue(forKey: id)
        projects.removeAll { $0.id == id }
        if selectedProjectID == id {
            selectedProjectID = projects.first?.id
            selectedConfigurationKey = nil
        }
        persistProjects()
    }

    func rescan(entryID: String) {
        guard let index = projects.firstIndex(where: { $0.id == entryID }) else { return }
        projects[index].isScanning = true
        projects[index].errorText = nil
        let url = projects[index].url

        // §100: 扫描不进主线程。
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanner = IntelliJProjectScanner()
            do {
                let result = try scanner.scan(projectRoot: url)
                let jdk = JDKResolver().resolve(configJDKName: nil, projectJDKName: result.projectJDKName)
                await self?.applyScan(path: url.path, result: result, jdk: jdk)
            } catch {
                await self?.applyScanError(path: url.path, message: Self.describe(error))
            }
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let lightRunError = error as? IdeaLightRunError {
            return "\(lightRunError.title)：\(lightRunError.reason)"
        }
        return error.localizedDescription
    }

    private func applyScan(path: String, result: ScanResult, jdk: JDKResolution) {
        guard let index = projects.firstIndex(where: { $0.id == path }) else { return }
        projects[index].result = result
        projects[index].projectJDK = jdk
        projects[index].isScanning = false

        if selectedProjectID == nil {
            selectedProjectID = path
        }
        if selectedProjectID == path, selectedConfigurationKey == nil {
            selectedConfigurationKey = result.configurations.first?.uniqueKey
        }
    }

    private func applyScanError(path: String, message: String) {
        guard let index = projects.firstIndex(where: { $0.id == path }) else { return }
        projects[index].isScanning = false
        projects[index].errorText = message
    }

    // MARK: - 持久化

    private func loadProjects() {
        guard let data = try? Data(contentsOf: Self.persistenceURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard url.hasDirectoryPath else { continue }
            let entry = ProjectEntry(url: url, result: nil, projectJDK: nil, errorText: nil, isScanning: false)
            projects.append(entry)
            rescan(entryID: entry.id)
        }
        selectedProjectID = projects.first?.id
    }

    private func persistProjects() {
        let directory = Self.persistenceURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(projects.map { $0.id }) else { return }
        try? data.write(to: Self.persistenceURL, options: .atomic)
    }
}
