import Foundation

/// 一个可安装的正式发布：下载地址 + GitHub 侧记录的 SHA-256。
/// 没有可信 digest 的产物一律不接受——镜像链的安全性完全依赖它。
public struct SoftwareRelease: Equatable, Sendable {
    public let version: SoftwareVersion
    public let tagName: String
    public let releaseNotes: String
    public let archiveURL: URL
    public let sha256: String

    public init(
        version: SoftwareVersion,
        tagName: String,
        releaseNotes: String,
        archiveURL: URL,
        sha256: String
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseNotes = releaseNotes
        self.archiveURL = archiveURL
        self.sha256 = sha256
    }

    /// 当前版本无法解析时返回 false：宁可提示「无更新」，也不能拿一个
    /// 未知版本的机器去覆盖成别人。
    public func isNewer(than currentVersion: String) -> Bool {
        guard let current = SoftwareVersion(currentVersion) else { return false }
        return current < version
    }

    static func selectAsset<T: AssetCandidate>(named candidates: [T], expectedName: String) -> (URL, String)? {
        guard let asset = candidates.first(where: { $0.assetName == expectedName }),
              asset.url.scheme == "https",
              let sha256 = asset.sha256Hex else {
            return nil
        }
        return (asset.url, sha256)
    }

    public static func decodeGitHubResponse(_ data: Data) throws -> SoftwareRelease {
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard !response.draft, !response.prerelease, let version = SoftwareVersion(response.tagName) else {
            throw UpdateError.invalidRelease
        }
        guard let asset = selectAsset(
            named: response.assets,
            expectedName: UpdateIdentity.archiveName(version: version.description)
        ) else {
            throw UpdateError.missingVerifiedArchive
        }
        return SoftwareRelease(
            version: version,
            tagName: response.tagName,
            releaseNotes: response.body,
            archiveURL: asset.0,
            sha256: asset.1
        )
    }

    /// GitHub API 按来源 IP 限流（403）。此时公开 Release 页面仍然暴露
    /// 同样的产物链接与 sha256 摘要，抓下来解析，可信度不因绕过 API 而降低。
    public static func decodeGitHubAssetsHTML(_ data: Data, tagName: String) throws -> SoftwareRelease {
        guard let version = SoftwareVersion(tagName) else { throw UpdateError.invalidRelease }
        let html = String(decoding: data, as: UTF8.self)
        let pattern = #"href="(/[^"]+/releases/download/[^/]+/([^"/]+\.zip))"[\s\S]*?sha256:([0-9a-fA-F]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw UpdateError.invalidRelease
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let candidates = regex.matches(in: html, range: range).compactMap { match -> HTMLAssetCandidate? in
            guard let pathRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let digestRange = Range(match.range(at: 3), in: html),
                  let url = URL(string: "https://github.com\(html[pathRange])") else {
                return nil
            }
            return HTMLAssetCandidate(
                name: String(html[nameRange]),
                url: url,
                digest: "sha256:" + String(html[digestRange]).lowercased()
            )
        }
        guard let asset = selectAsset(
            named: candidates,
            expectedName: UpdateIdentity.archiveName(version: version.description)
        ) else {
            throw UpdateError.missingVerifiedArchive
        }
        return SoftwareRelease(
            version: version,
            tagName: tagName,
            releaseNotes: "",
            archiveURL: asset.0,
            sha256: asset.1
        )
    }
}

/// 产物候选：JSON 与 HTML 两条解析路径共用「精确名 + https + 合法 sha256」这一判定。
protocol AssetCandidate {
    var assetName: String { get }
    var url: URL { get }
    var digest: String? { get }
}

extension AssetCandidate {
    var sha256Hex: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let value = String(digest.dropFirst("sha256:".count)).lowercased()
        return value.count == 64 && value.allSatisfy(\.isHexDigit) ? value : nil
    }
}

struct HTMLAssetCandidate: AssetCandidate {
    let name: String
    let url: URL
    let digest: String?
    var assetName: String { name }
}

private struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable, AssetCandidate {
        let name: String
        let url: URL
        let digest: String?
        var assetName: String { name }

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case assets
    }
}
