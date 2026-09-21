import Foundation

/// 带镜像回退的产物下载。GitHub 直连在国内经常下不动，而镜像是第三方，
/// 因此这条链的信任锚点只有一个：文件的 SHA-256 必须等于发布记录里的 digest。
/// 校验不过就删掉换下一个源，最后一个源永远是 GitHub 本身。
public enum UpdateArchiveDownloader {
    /// 只重写本仓库公开 Release 的下载地址；其余 URL 原样返回。
    public static func sources(for original: URL, preferredHost: String? = nil) -> [URL] {
        guard original.scheme == "https", original.host == "github.com",
              original.user == nil, original.password == nil, original.port == nil,
              original.path.hasPrefix("/\(UpdateIdentity.githubRepository)/releases/download/"),
              var mirror = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            return [original]
        }
        mirror.host = "xget.xi-xu.me"
        // 保留 percentEncodedPath：产物名里出现空格时不能提前解码。
        mirror.percentEncodedPath = "/gh" + mirror.percentEncodedPath
        guard let xgetURL = mirror.url else { return [original] }

        var candidates = [xgetURL] + ["ghfast.top", "gh-proxy.org"].compactMap {
            URL(string: "https://\($0)/\(original.absoluteString)")
        }
        if let index = candidates.firstIndex(where: { $0.host == preferredHost }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        return candidates + [original]
    }

    public static func download(
        release: SoftwareRelease,
        preferredHost: String? = nil,
        didVerifySource: @Sendable (URL) -> Void = { _ in },
        fetch: @Sendable (URLRequest) async throws -> (URL, URLResponse)
    ) async throws -> URL {
        var lastError: any Error = UpdateError.invalidResponse
        for source in sources(for: release.archiveURL, preferredHost: preferredHost) {
            try Task.checkCancellation()
            var request = URLRequest(url: source)
            // 只约束「连不上/不吐字节」的空闲超时：活跃传输不受限，
            // 但坏掉的镜像不能拖到把最后一个源（GitHub）饿死。
            request.timeoutInterval = 15
            request.setValue(UpdateIdentity.applicationName, forHTTPHeaderField: "User-Agent")
            do {
                let (file, response) = try await fetch(request)
                do {
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw UpdateError.invalidResponse
                    }
                    let digest = try await Task.detached(priority: .utility) {
                        try UpdatePackageValidator.sha256(of: file)
                    }.value
                    guard digest == release.sha256 else { throw UpdateError.digestMismatch }
                    didVerifySource(source)
                    return file
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                try Task.checkCancellation()
                lastError = error
                UpdateLog.append("Download source \(source.host ?? "unknown") failed: \(error)")
            }
        }
        throw lastError
    }
}
