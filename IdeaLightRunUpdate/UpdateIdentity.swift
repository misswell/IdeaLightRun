import Foundation

/// 在线更新的 identifiers：GitHub 仓库、包标识、产物命名。
/// 值必须与 `scripts/build-app.sh` 写进 Info.plist 的内容以及
/// `.github/workflows/release.yml` 上传的附件名保持一致——三处任一分裂，
/// 检查就永远拿不到可比对的产物。`UpdateIdentityTests` 会读脚本原文来守这条线。
public enum UpdateIdentity {
    public static let githubRepository = "misswell/IdeaLightRun"
    public static let applicationName = "IdeaLightRun"
    public static let bundleIdentifier = "com.idealightrun.app"
    public static let executableName = "IdeaLightRun"
    public static let updaterExecutableName = "IdeaLightRunUpdater"
    /// 所有正式包必须由该 Team 的 Developer ID 签名；换证书等于换身份，
    /// 老用户会收到「签名校验不通过」而不是被静默替换。
    public static let developerTeamIdentifier = "U8U443D7ZL"

    /// 发布产物名（通用二进制）。release.yml 同时上传 SHA256SUMS.txt，
    /// 因此这里按精确名匹配而不是「第一个 zip」。
    public static func archiveName(version: String) -> String {
        "\(applicationName)-\(version)-universal.zip"
    }

    public static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/\(githubRepository)/releases/latest")!
    public static let latestReleasePageURL =
        URL(string: "https://github.com/\(githubRepository)/releases/latest")!
    public static let releasePageURL = latestReleasePageURL

    public static func expandedAssetsURL(tagName: String) -> URL? {
        URL(string: "https://github.com/\(githubRepository)/releases/expanded_assets/\(tagName)")
    }

    /// 最近一次校验通过的镜像 host。存 UserDefaults 而不是内存：重启后仍生效，
    /// 但只允许是 `UpdateArchiveDownloader` 白名单里的镜像（未知 host 会被忽略）。
    public static let mirrorPreferenceKey = "\(bundleIdentifier).updateDownloadMirrorHost"

    /// App 与更新助手共用的日志落点（用户可自查，不弹窗时也能复盘失败原因）。
    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(applicationName)/update.log")
    }

    public static func isOurBundle(_ identifier: String?) -> Bool {
        identifier == bundleIdentifier
    }
}

public enum UpdateLog {
    /// 追加一行带时间戳的日志。更新链路任一环节失败都要留下证据，
    /// 但日志本身写失败不能把更新流程带崩，因此全部 best-effort。
    public static func append(_ message: String, to url: URL = UpdateIdentity.logURL) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? Data(line.utf8).write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
