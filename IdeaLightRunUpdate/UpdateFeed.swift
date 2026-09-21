import Foundation

/// 取最新发布：GitHub API 优先，被限流（403）时退回公开的 releases 页面。
/// 两条路径都只做「读元数据」，产物本身的可信度由 SHA-256 决定。
public struct UpdateFeed: Sendable {
    private let session: URLSession
    private let currentVersion: String

    public init(session: URLSession = .shared, currentVersion: String) {
        self.session = session
        self.currentVersion = currentVersion
    }

    public func latestRelease() async throws -> SoftwareRelease {
        let (data, response) = try await get(UpdateIdentity.latestReleaseURL, accept: "application/vnd.github+json")
        switch statusCode(of: response) {
        case 200:
            return try SoftwareRelease.decodeGitHubResponse(data)
        case 403:
            // 匿名 API 按共享出口 IP 限流，403 不代表发布不存在。
            return try await latestReleaseFromWeb()
        default:
            throw UpdateError.invalidResponse
        }
    }

    private func latestReleaseFromWeb() async throws -> SoftwareRelease {
        // /releases/latest 会 302 到具体 tag，跟随重定向后的末段路径即版本号。
        let (_, tagResponse) = try await get(UpdateIdentity.latestReleasePageURL)
        guard statusCode(of: tagResponse) == 200,
              let finalURL = tagResponse.url,
              let tagName = finalURL.pathComponents.last,
              !tagName.isEmpty,
              tagName != "latest" else {
            throw UpdateError.invalidResponse
        }
        guard let assetsURL = UpdateIdentity.expandedAssetsURL(tagName: tagName) else {
            throw UpdateError.invalidResponse
        }
        let (assetsData, assetsResponse) = try await get(assetsURL)
        guard statusCode(of: assetsResponse) == 200 else { throw UpdateError.invalidResponse }
        return try SoftwareRelease.decodeGitHubAssetsHTML(assetsData, tagName: tagName)
    }

    private func get(_ url: URL, accept: String? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return try await session.data(for: request)
    }

    private func statusCode(of response: URLResponse?) -> Int? {
        (response as? HTTPURLResponse)?.statusCode
    }

    private var userAgent: String { "\(UpdateIdentity.applicationName)/\(currentVersion)" }
}
