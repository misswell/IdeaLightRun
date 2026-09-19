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

    private static let persistenceURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IdeaLightRun/projects.json")

    init() {
        AppStore.current = self
        loadProjects()
    }

    var selectedProject: ProjectEntry? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedConfiguration: RunConfiguration? {
        guard let key = selectedConfigurationKey else { return nil }
        return selectedProject?.result?.configurations.first { $0.uniqueKey == key }
    }

    // MARK: - 运行管理（§32–§35）

    func run(configKey: String) {
        guard let project = selectedProject,
              let config = project.result?.configurations.first(where: { $0.uniqueKey == configKey }) else {
            return
        }
        guard config.type == .application || config.type == .springBoot else {
            alertMessage = "“\(config.name)”（\(config.type.displayName)）当前不支持直接启动。"
            return
        }
        guard project.result?.buildSystem.maven != nil else {
            alertMessage = "当前版本仅支持 Maven 项目直接启动；Gradle 支持在 Milestone 4 提供。"
            return
        }
        // §35: 已有终态会话时替换；运行/构建中由 UI 禁用 ▶
        if let existing = sessions[configKey], !existing.state.isTerminal {
            return
        }
        sessions.removeValue(forKey: configKey)

        let model = RunningProcessModel(configKey: configKey, configName: config.name, projectPath: project.id)
        model.onRestartNeeded = { [weak self] in
            self?.run(configKey: configKey)
        }
        sessions[configKey] = model
        selectedConfigurationKey = configKey

        let projectRoot = project.url
        let launcher = JavaLauncher()
        let handle = ProcessHandle()
        model.buildHandle = handle
        Task.detached(priority: .userInitiated) {
            do {
                let plan = try await launcher.prepare(
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
                let session = try ProcessSession(
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
                }
            } catch {
                await model.pipelineFailed(error.localizedDescription)
            }
        }
    }

    /// §33: 构建期 Stop → 终止 Maven 构建；运行期 Stop → SIGTERM，
    /// 3 秒后仍存活由用户决定 Force Kill。
    func stop(configKey: String) {
        guard let model = sessions[configKey] else { return }
        switch model.state {
        case .preparing, .resolvingClasspath, .building, .starting:
            model.buildHandle?.terminate()
        case .running:
            model.session?.stop()
        case .stopping, .exited, .cancelled, .failed:
            break
        }
    }

    func forceKill(configKey: String) {
        guard let model = sessions[configKey] else { return }
        if model.state == .stopping {
            model.session?.forceKill()
        } else if model.isActiveBuildPhase {
            model.buildHandle?.forceKill()
        }
    }

    /// §34: 等旧进程退出后再重新走完整流水线。
    func restart(configKey: String) {
        if let model = sessions[configKey], !model.state.isTerminal {
            if model.isRunning {
                model.pendingRestart = true
                model.session?.stop()
            }
            // 构建期不允许重启（Stop 后可重新 Run）
            return
        }
        sessions.removeValue(forKey: configKey)
        run(configKey: configKey)
    }

    func state(for configKey: String) -> ProcessState? {
        sessions[configKey]?.state
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
        // 停掉该项目正在运行的服务
        for model in sessions.values where model.projectPath == id {
            model.session?.stop()
        }
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
