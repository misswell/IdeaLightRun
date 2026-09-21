import CryptoKit
import Foundation

/// 已通过全部校验、可以直接替换到磁盘上的新版本。
/// `workingDirectory` 是暂存根目录，由安装助手在替换结束后统一删除。
public struct VerifiedUpdatePackage: Sendable {
    public let applicationURL: URL
    public let workingDirectory: URL
}

/// 把下载到的 zip 变成一个「敢装上盘」的 .app。顺序即防线，任一步失败都清掉
/// 暂存目录并抛出可展示的原因——绝不会留下半个新版本。
public enum UpdatePackageValidator {
    public static func prepare(downloadURL: URL, release: SoftwareRelease) throws -> VerifiedUpdatePackage {
        guard try sha256(of: downloadURL) == release.sha256 else {
            throw UpdateError.digestMismatch
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UpdateIdentity.applicationName)Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        do {
            let archiveURL = workingDirectory.appendingPathComponent("update.zip")
            try FileManager.default.copyItem(at: downloadURL, to: archiveURL)
            // ditto 而不是 unzip：只有它保留 resource fork、权限与符号链接，
            // 用 unzip 解出来的 bundle 会因为丢元数据而签名失效。
            try Shell.runChecked("/usr/bin/ditto", ["-x", "-k", archiveURL.path, workingDirectory.path],
                                 failure: UpdateError.invalidApplication)

            let applicationURL = try stagedApplication(in: workingDirectory, release: release)
            try verifySignature(of: applicationURL)
            stripQuarantine(from: applicationURL)
            return VerifiedUpdatePackage(applicationURL: applicationURL, workingDirectory: workingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    /// 结构自检：必须是我们自己的 bundle、可执行文件在位、版本号对得上，
    /// 而且新版本里必须自带更新助手——否则这次更新会把「能自动更新」这个能力弄丢。
    private static func stagedApplication(in workingDirectory: URL, release: SoftwareRelease) throws -> URL {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        guard let applicationURL = candidates.first(where: {
            $0.pathExtension == "app"
                && FileManager.default.isExecutableFile(
                    atPath: $0.appendingPathComponent("Contents/MacOS/\(UpdateIdentity.executableName)").path
                )
        }), let bundle = Bundle(url: applicationURL),
           UpdateIdentity.isOurBundle(bundle.bundleIdentifier),
           bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == UpdateIdentity.executableName,
           FileManager.default.isExecutableFile(
               atPath: applicationURL.appendingPathComponent("Contents/MacOS/\(UpdateIdentity.updaterExecutableName)").path
           ) else {
            throw UpdateError.invalidApplication
        }
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard shortVersion.flatMap(SoftwareVersion.init) == release.version else {
            throw UpdateError.versionMismatch
        }
        return applicationURL
    }

    private static func verifySignature(of applicationURL: URL) throws {
        try Shell.runChecked("/usr/bin/codesign",
                             ["--verify", "--deep", "--strict", applicationURL.path],
                             failure: UpdateError.invalidSignature)
        let details = try Shell.runChecked("/usr/bin/codesign",
                                           ["--display", "--verbose=4", applicationURL.path],
                                           failure: UpdateError.invalidSignature)
        guard details.contains("TeamIdentifier=\(UpdateIdentity.developerTeamIdentifier)") else {
            throw UpdateError.wrongDeveloperTeam
        }
        // 系统授权（辅助功能、屏幕录制、自动化…）记的是「授予时那套签名要求」，
        // 校验方式是让新版本去 satisfy 它。两套 designated requirement 的文本
        // 未必逐字相同（签名机看不到 Apple 中间证书时会写出更弱的一条），
        // 比文本会把合法更新判成身份变更，所以这里按语义比。
        let runningRequirement = try designatedRequirement(of: Bundle.main.bundleURL)
        guard !runningRequirement.isEmpty, satisfies(runningRequirement, at: applicationURL) else {
            throw UpdateError.identityMismatch
        }
        try Shell.runChecked("/usr/sbin/spctl",
                             ["--assess", "--type", "execute", applicationURL.path],
                             failure: UpdateError.gatekeeperRejected)
    }

    /// 当前运行的应用的 designated requirement（`codesign -d -r-` 里 `=> ` 之后的部分）。
    public static func designatedRequirement(of bundleURL: URL) throws -> String {
        let output = try Shell.runChecked(
            "/usr/bin/codesign",
            ["--display", "-r-", bundleURL.path],
            failure: UpdateError.invalidSignature
        )
        return parseDesignatedRequirement(from: output)
    }

    public static func parseDesignatedRequirement(from codesignOutput: String) -> String {
        for line in codesignOutput.split(separator: "\n") where line.contains("designated") {
            if let range = line.range(of: "=> ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// macOS 校验隐私授权时做的正是这一步，因此它也是「更新后授权还在不在」的正确判据。
    public static func satisfies(_ requirement: String, at bundleURL: URL) -> Bool {
        guard !requirement.isEmpty else { return false }
        let outcome = try? Shell.run("/usr/bin/codesign", ["--verify", "--strict", "-R", "=\(requirement)", bundleURL.path])
        return outcome?.succeeded ?? false
    }

    /// 递归去掉隔离属性。漏掉它的话，重启后的 app 会被 App Translocation
    /// 搬到一个随机只读路径，用户已有的每一项系统授权都要重新点一遍。
    private static func stripQuarantine(from applicationURL: URL) {
        _ = try? Shell.run("/usr/bin/xattr", ["-r", "-d", "com.apple.quarantine", applicationURL.path])
    }

    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
