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
    static var current: AppStore?

    @Published private(set) var projects: [ProjectEntry] = []
    @Published var selectedProjectID: String?
    @Published var selectedConfigurationKey: String?
    @Published var alertMessage: String?
    /// configKey → 运行会话（含构建阶段）
    @Published private(set) var sessions: [String: RunningProcessModel] = [:]
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
        AppStore.current = self
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

    /// 当前项目的最近一次构建（菜单项"停止构建"用）
    var currentBuild: ProjectBuildModel? {
        selectedProjectID.flatMap { builds[$0] }
    }

    /// 仍在运行的服务数：更新面板据此说明「安装会把它们停掉」。
    var activeSessionCount: Int {
        sessions.values.filter { !$0.state.isTerminal }.count
    }

    /// 菜单命令的入口。`Commands.body` 在旧 SDK（CI 的 Xcode 15 / Swift 5.10）上不是
    /// `@MainActor`，闭包没法直接调主 actor 方法；显式走这里，两种工具链都成立。
    nonisolated static func fromMenu(_ action: @escaping @MainActor (AppStore) -> Void) {
        Task { @MainActor in
            guard let store = current else { return }
            action(store)
        }
    }

    // MARK: - 运行管理（§32–§35）

    func run(configKey: String, projectID: String? = nil) {
        let project = projectID.flatMap { id in projects.first { $0.id == id } } ?? selectedProject
        guard let project,
              let config = project.result?.configurations.first(where: { $0.uniqueKey == configKey }) else {
            return
        }
        // §23: 这里不再判断配置类型与构建系统——能不能跑由 Core 决定，
        // 跑不了的配置会以 unsupportedConfiguration 明确报出来。
        // §35: 已有终态会话时替换；运行/构建中由 UI 禁用 ▶
        if let existing = sessions[configKey], !existing.state.isTerminal {
            return
        }
        sessions.removeValue(forKey: configKey)

        let model = RunningProcessModel(configKey: configKey, configName: config.name, projectPath: project.id)
        model.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        // 重启可能发生在用户切换项目之后，必须锁定发起时的项目而不是当时的 selectedProject。
        model.onRestartNeeded = { [weak self] in
            self?.run(configKey: configKey, projectID: project.id)
        }
        sessions[configKey] = model
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
                if handle.isCancelled {
                    await model.setPipelineState(.cancelled)
                    return
                }
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

    /// §33: 构建期 Stop → 终止 Maven 构建；运行期 Stop → SIGTERM，
    /// 3 秒后仍存活由用户决定 Force Kill。
    func stop(configKey: String) {
        guard let model = sessions[configKey], !model.state.isTerminal else { return }
        // model.state 经主线程异步投递，构建期/运行期的边界上可能仍是旧值；
        // 两个通道都发一次，避免 Stop 落空（已结束的句柄是 no-op）。
        model.buildHandle?.terminate()
        model.session?.stop()
    }

    func forceKill(configKey: String) {
        guard let model = sessions[configKey], !model.state.isTerminal else { return }
        model.session?.forceKill()
        model.buildHandle?.forceKill()
    }

    /// §34: 等旧进程退出后再重新走完整流水线。
    func restart(configKey: String) {
        let projectID = sessions[configKey]?.projectPath
        if let model = sessions[configKey], !model.state.isTerminal {
            if model.isRunning {
                model.pendingRestart = true
                model.session?.stop()
            }
            // 构建期不允许重启（Stop 后可重新 Run）
            return
        }
        sessions.removeValue(forKey: configKey)
        run(configKey: configKey, projectID: projectID)
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

    func removeProject(id: String) {
        // 停掉该项目正在运行的服务，并丢弃其会话（否则 configKey 会残留到同名项目重新添加时）
        let ownedKeys = sessions.compactMap { $0.value.projectPath == id ? $0.key : nil }
        for key in ownedKeys {
            stop(configKey: key)
            sessions.removeValue(forKey: key)
        }
        builds[id]?.handle?.terminate()
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
