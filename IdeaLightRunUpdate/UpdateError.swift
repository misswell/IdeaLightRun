import Foundation

/// 更新链路的错误。按 §109 的 title / reason / suggestion 三段呈现：
/// 失败必须说清「哪一步、为什么、下一步做什么」，不给笼统的「更新失败」。
public enum UpdateError: Error, Equatable, Sendable {
    case invalidRelease
    case missingVerifiedArchive
    case invalidResponse
    case digestMismatch
    case invalidApplication
    case versionMismatch
    case invalidSignature
    case wrongDeveloperTeam
    case identityMismatch
    case gatekeeperRejected
    case installationUnavailable
    case updaterHelperMissing
    case currentVersionUnreadable(String)
    case commandFailed(String)
}

extension UpdateError {
    public var title: String {
        switch self {
        case .invalidRelease, .missingVerifiedArchive, .invalidResponse: return "读取版本信息失败"
        case .digestMismatch: return "下载文件校验不通过"
        case .invalidApplication, .versionMismatch, .invalidSignature,
             .wrongDeveloperTeam, .identityMismatch, .gatekeeperRejected: return "新版本校验不通过"
        case .installationUnavailable: return "当前安装位置无法更新"
        case .updaterHelperMissing: return "缺少更新助手"
        case .currentVersionUnreadable: return "无法识别当前版本号"
        case .commandFailed: return "系统命令执行失败"
        }
    }

    public var reason: String {
        switch self {
        case .invalidRelease: return "最新发布记录不是可安装的版本（可能是草稿、预发布或 tag 不是 X.Y.Z）。"
        case .missingVerifiedArchive: return "最新发布里没有带 SHA-256 的 \(UpdateIdentity.applicationName) 安装包。"
        case .invalidResponse: return "GitHub 返回了无法处理的响应。"
        case .digestMismatch: return "文件的 SHA-256 与 GitHub 发布记录不一致，可能是下载被截断或被中途替换。"
        case .invalidApplication: return "解压出的 .app 结构不完整（可执行文件、Info.plist 或更新助手缺失）。"
        case .versionMismatch: return "解压出的 .app 版本号与发布记录对不上。"
        case .invalidSignature: return "新版本的代码签名校验失败。"
        case .wrongDeveloperTeam: return "新版本不是由 Team \(UpdateIdentity.developerTeamIdentifier) 签名的。"
        case .identityMismatch: return "新版本的签名身份与当前运行的应用不一致，装上会丢掉已有的系统授权。"
        case .gatekeeperRejected: return "Gatekeeper 拒绝运行新版本。"
        case .installationUnavailable: return "应用所在目录不可写，或正从只读的隔离路径运行。"
        case .updaterHelperMissing: return "当前运行的这个版本里没有 IdeaLightRunUpdater，进程外替换无从完成。"
        case .currentVersionUnreadable(let value): return "本机版本号 \u{201c}\(value)\u{201d} 不是 X.Y.Z 形式，无法与线上版本比较。"
        case .commandFailed(let detail): return detail
        }
    }

    public var suggestion: String {
        switch self {
        case .invalidRelease, .missingVerifiedArchive, .invalidResponse:
            return "稍后重试，或到 Release 页面确认最新的正式版。"
        case .digestMismatch:
            return "重新下载一次；若持续失败，改用网络代理或到 Release 页面手动下载。"
        case .invalidApplication, .versionMismatch, .invalidSignature,
             .wrongDeveloperTeam, .identityMismatch, .gatekeeperRejected:
            return "本次安装包已丢弃，当前版本未受影响。请到 Release 页面手动下载，并核对 SHA256SUMS.txt。"
        case .installationUnavailable:
            return "把 IdeaLightRun.app 拖进「应用程序」文件夹后再试（不要从 DMG 或只读路径运行）。"
        case .updaterHelperMissing:
            return "从这个版本起才支持在线更新。请到 Release 页面手动下载安装一次，之后的更新就能自动完成。"
        case .currentVersionUnreadable:
            return "这是未打 tag 的开发构建，请走手动替换。"
        case .commandFailed:
            return "查看 ~/Library/Logs/\(UpdateIdentity.applicationName)/update.log 里的原始输出。"
        }
    }
}

/// 网络/URLSession 等库内错误统一成一条可展示的失败，避免把
/// `The operation couldn’t be completed.` 直接甩给用户。
public struct UpdateFailure: Equatable, Sendable {
    public let title: String
    public let reason: String
    public let suggestion: String

    public init(_ error: Error) {
        if let error = error as? UpdateError {
            title = error.title
            reason = error.reason
            suggestion = error.suggestion
            return
        }
        if error is CancellationError {
            title = "已取消"
            reason = "更新已中止。"
            suggestion = "需要时重新点「检查更新…」。"
            return
        }
        title = "连接失败"
        reason = error.localizedDescription
        suggestion = "检查网络后重试；也可以到 Release 页面手动下载。"
    }

    public init(title: String, reason: String, suggestion: String) {
        self.title = title
        self.reason = reason
        self.suggestion = suggestion
    }
}
