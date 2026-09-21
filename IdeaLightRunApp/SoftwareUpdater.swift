import AppKit
import Combine
import IdeaLightRunUpdate

/// 在线更新的编排：检查 → 下载 → 校验 → 交给更新助手 → 退出。
/// §64 的约束在这里被刻意收紧成「只有用户点『检查更新…』才联网」：
/// 没有启动自查，也没有后台定时器。
@MainActor
final class SoftwareUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(latest: SoftwareRelease, current: String)
        case available(SoftwareRelease)
        case downloading(SoftwareRelease)
        case installing(SoftwareRelease)
        case failed(UpdateFailure)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }

        /// 助手已经接手：此时取消既救不了什么，还会让用户以为能撤回。
        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var isPresented = false

    let currentVersion: String
    private let feed: UpdateFeed
    private let session: URLSession
    private let applicationURL: URL
    private var job: Task<Void, Never>?

    init(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        session: URLSession = .shared,
        applicationURL: URL = Bundle.main.bundleURL
    ) {
        self.currentVersion = currentVersion
        self.session = session
        self.feed = UpdateFeed(session: session, currentVersion: currentVersion)
        self.applicationURL = applicationURL
    }

    var releasePageURL: URL { UpdateIdentity.releasePageURL }

    /// 菜单入口：每次点都把面板拉起来并真的去查一次。
    /// 不做「上次查过就用缓存」——用户主动问，就该拿到新鲜答案。
    func checkFromMenu() {
        isPresented = true
        guard !phase.isBusy else { return }
        job = Task { await self.check() }
    }

    func install() {
        guard !phase.isBusy else { return }
        job = Task { await self.downloadAndInstall() }
    }

    /// 中止只做一件事：取消任务。下载/替换走到哪一步都由各自的
    /// `Task.checkCancellation()` 收尾，不留半截文件在盘上。
    func cancel() {
        guard !phase.isInstalling else { return }
        job?.cancel()
        job = nil
        if phase.isBusy { phase = .idle }
    }

    func check() async {
        guard !phase.isBusy else { return }
        guard SoftwareVersion(currentVersion) != nil else {
            phase = .failed(UpdateFailure(UpdateError.currentVersionUnreadable(currentVersion)))
            return
        }
        phase = .checking
        do {
            let release = try await feed.latestRelease()
            guard !Task.isCancelled else { return }
            phase = release.isNewer(than: currentVersion)
                ? .available(release)
                : .upToDate(latest: release, current: currentVersion)
            UpdateLog.append("检查完成：线上 \(release.tagName)，本机 \(currentVersion)")
        } catch {
            recordFailure(error, stage: "检查")
        }
    }

    func downloadAndInstall() async {
        guard case .available(let release) = phase else { return }
        phase = .downloading(release)
        do {
            let downloadURL = try await UpdateArchiveDownloader.download(
                release: release,
                preferredHost: UserDefaults.standard.string(forKey: UpdateIdentity.mirrorPreferenceKey),
                didVerifySource: { source in Self.rememberMirror(source) }
            ) { [session] request in
                try await session.download(for: request)
            }
            defer { try? FileManager.default.removeItem(at: downloadURL) }
            try Task.checkCancellation()
            phase = .installing(release)
            let package = try await Task.detached(priority: .userInitiated) {
                try UpdatePackageValidator.prepare(downloadURL: downloadURL, release: release)
            }.value
            // detached 子任务不继承取消：校验期间被取消也要在这里拦住，
            // 否则会绕过一个已取消的意图去真的替换 app。
            try Task.checkCancellation()
            try launchInstaller(for: package)
            UpdateLog.append("已移交更新助手：\(release.tagName)")
            NSApp.terminate(nil)
        } catch {
            recordFailure(error, stage: "安装")
        }
    }

    private func recordFailure(_ error: Error, stage: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            phase = .idle
            return
        }
        UpdateLog.append("\(stage)失败：\(error)")
        phase = .failed(UpdateFailure(error))
    }

    /// 记住最近一次可用的镜像；直连成功则清掉偏好，避免网络变好后还一直绕远路。
    /// UserDefaults 本身线程安全，所以这里保持 nonisolated，供下载回调直接调用。
    private nonisolated static func rememberMirror(_ source: URL) {
        let host = source.host ?? ""
        if host.isEmpty || host == "github.com" {
            UserDefaults.standard.removeObject(forKey: UpdateIdentity.mirrorPreferenceKey)
        } else {
            UserDefaults.standard.set(host, forKey: UpdateIdentity.mirrorPreferenceKey)
        }
    }

    /// 替换前把「装不装得下去」判清楚。别等到助手那侧才失败——那时主进程已经退出，
    /// 用户只会看到 app 凭空消失。
    private func launchInstaller(for package: VerifiedUpdatePackage) throws {
        let runningBundleURL = Bundle.main.bundleURL
        guard !runningBundleURL.path.contains("/AppTranslocation/"),
              applicationURL.pathExtension == "app",
              UpdateIdentity.isOurBundle(Bundle(url: applicationURL)?.bundleIdentifier),
              FileManager.default.isWritableFile(atPath: applicationURL.deletingLastPathComponent().path) else {
            throw UpdateError.installationUnavailable
        }
        let bundledHelper = applicationURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(UpdateIdentity.updaterExecutableName)
        guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else {
            throw UpdateError.updaterHelperMissing
        }

        // 先把助手拷出 bundle：它即将被替换，正在执行的自身映像不能留在里面。
        let helperDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UpdateIdentity.updaterExecutableName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helperURL = helperDirectory.appendingPathComponent(UpdateIdentity.updaterExecutableName)
        try FileManager.default.copyItem(at: bundledHelper, to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let process = Process()
        process.executableURL = helperURL
        process.arguments = UpdaterRequest(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            sourceApplication: package.applicationURL,
            destinationApplication: applicationURL,
            stagingDirectory: package.workingDirectory,
            helperDirectory: helperDirectory,
            logURL: UpdateIdentity.logURL
        ).processArguments
        try process.run()
    }
}
