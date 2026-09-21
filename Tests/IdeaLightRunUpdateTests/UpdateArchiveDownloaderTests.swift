import Foundation
import XCTest

@testable import IdeaLightRunUpdate

/// 记录跨 `@Sendable` 闭包收集到的调用轨迹；下载是串行的，锁只为了保护 Swift 6 的发送性检查。
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    private var _files: [URL] = []
    private var _timeouts: [TimeInterval] = []
    private var _userAgents: [String?] = []

    func record(host: String, file: URL? = nil, request: URLRequest) {
        lock.lock()
        _hosts.append(host)
        if let file { _files.append(file) }
        _timeouts.append(request.timeoutInterval)
        _userAgents.append(request.value(forHTTPHeaderField: "User-Agent"))
        lock.unlock()
    }

    var hosts: [String] { lock.lock(); defer { lock.unlock() }; return _hosts }
    var files: [URL] { lock.lock(); defer { lock.unlock() }; return _files }
    var timeouts: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _timeouts }
    var userAgents: [String?] { lock.lock(); defer { lock.unlock() }; return _userAgents }
}

/// 镜像链的唯一前提：无论谁把字节送到本机，SHA-256 都必须等于 GitHub 发布记录里的值。
final class UpdateArchiveDownloaderTests: XCTestCase {
    /// sha256("hello")
    private static let goodDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    private static let mirrors = ["xget.xi-xu.me", "ghfast.top", "gh-proxy.org"]

    private var staging: URL!
    private var goodFile: URL!
    private var release: SoftwareRelease!

    override func setUpWithError() throws {
        staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        goodFile = try write(Data("hello".utf8), named: "good.zip")
        release = SoftwareRelease(
            version: SoftwareVersion("0.1.6")!,
            tagName: "v0.1.6",
            releaseNotes: "",
            archiveURL: URL(string: "https://github.com/misswell/IdeaLightRun/releases/download/v0.1.6/IdeaLightRun-0.1.6-universal.zip")!,
            sha256: Self.goodDigest
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: staging)
    }

    @discardableResult
    private func write(_ data: Data, named name: String) throws -> URL {
        let url = staging.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func response(for url: URL, status: Int) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - 源列表

    func testOnlyRewritesOurOwnGitHubReleaseURLs() {
        let sources = UpdateArchiveDownloader.sources(for: release.archiveURL)
        XCTAssertEqual(sources.map(\.host), Self.mirrors + ["github.com"])
        XCTAssertEqual(sources.last, release.archiveURL)

        let foreign = URL(string: "https://github.com/other/Repo/releases/download/v1/asset.zip")!
        XCTAssertEqual(UpdateArchiveDownloader.sources(for: foreign), [foreign], "不能给别的仓库改写下载地址")
        let insecure = URL(string: "http://github.com/misswell/IdeaLightRun/releases/download/v1/a.zip")!
        XCTAssertEqual(UpdateArchiveDownloader.sources(for: insecure), [insecure], "不做 https 直连的不改写")
        let asset = URL(string: "https://github.com/misswell/IdeaLightRun/releases/expanded_assets/v0.1.6")!
        XCTAssertEqual(UpdateArchiveDownloader.sources(for: asset), [asset])
    }

    func testPreviouslyUsableMirrorMovesToFrontAndGitHubStaysLast() {
        let sources = UpdateArchiveDownloader.sources(for: release.archiveURL, preferredHost: "gh-proxy.org")
        XCTAssertEqual(sources.map(\.host), ["gh-proxy.org"] + ["xget.xi-xu.me", "ghfast.top"] + ["github.com"])
    }

    /// 偏好值来自磁盘，被写成未知 host 时不能变成「从任意第三方下包」。
    func testUnknownPreferredHostIsIgnored() {
        let sources = UpdateArchiveDownloader.sources(for: release.archiveURL, preferredHost: "evil.example.com")
        XCTAssertEqual(sources.map(\.host), Self.mirrors + ["github.com"])
    }

    func testMirrorRewriteKeepsPercentEncodedPath() {
        let url = URL(string: "https://github.com/misswell/IdeaLightRun/releases/download/v0.1.6/IdeaLightRun%200.1.6-universal.zip")!
        let mirror = UpdateArchiveDownloader.sources(for: url).first!
        let encoded = URLComponents(url: mirror, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        XCTAssertTrue(encoded.hasPrefix("/gh/misswell/IdeaLightRun/releases/download/v0.1.6/IdeaLightRun%200.1.6"), encoded)
    }

    // MARK: - 逐个源回退

    func testFirstHealthySourceWinsAndStopsTheChain() async throws {
        let trace = Trace()
        let verifiedHosts = Trace()
        let url = try await UpdateArchiveDownloader.download(
            release: release,
            didVerifySource: { verifiedHosts.record(host: $0.host ?? "", file: self.goodFile, request: URLRequest(url: $0)) }
        ) { request in
            trace.record(host: request.url?.host ?? "", file: self.goodFile, request: request)
            return (self.goodFile, self.response(for: request.url!, status: 200))
        }
        XCTAssertEqual(url, goodFile)
        XCTAssertEqual(trace.hosts, ["xget.xi-xu.me"], "首个源成功就不该再打扰后面的源")
        XCTAssertEqual(verifiedHosts.hosts, ["xget.xi-xu.me"])
    }

    func testStalledMirrorsFallThroughToGitHub() async throws {
        let trace = try await runFailingMirrors { host in
            guard host != "github.com" else { return (self.goodFile, self.response(for: URL(string: "https://github.com/x")!, status: 200)) }
            throw URLError(.timedOut)
        }
        XCTAssertEqual(trace.hosts, Self.mirrors + ["github.com"])
        XCTAssertEqual(trace.timeouts, [15, 15, 15, 15], "空闲超时必须收紧，坏镜像不能饿死最后一个源")
        XCTAssertEqual(trace.userAgents, [UpdateIdentity.applicationName, UpdateIdentity.applicationName, UpdateIdentity.applicationName, UpdateIdentity.applicationName])
    }

    func testHTTPErrorFromMirrorFallsThroughAndDeletesItsPartialFile() async throws {
        let partial = try write(Data("half".utf8), named: "partial.zip")
        let trace = try await runFailingMirrors { host in
            guard host != "github.com" else { return (self.goodFile, self.response(for: URL(string: "https://github.com/x")!, status: 200)) }
            return (partial, self.response(for: URL(string: "https://\(host)")!, status: 500))
        }
        XCTAssertEqual(trace.hosts, Self.mirrors + ["github.com"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "非 200 的下载必须删掉")
    }

    /// 镜像被投毒时唯一的防线就是 digest：换下一个源，而不是装上它。
    func testDigestMismatchFallsThroughAndDeletesEachBadFile() async throws {
        let trace = Trace()
        let verifiedHosts = Trace()
        let url = try await UpdateArchiveDownloader.download(
            release: release,
            didVerifySource: { verifiedHosts.record(host: $0.host ?? "", file: self.goodFile, request: URLRequest(url: $0)) }
        ) { request in
            let host = request.url?.host ?? ""
            // 每次尝试都当作一份新落到磁盘的文件，才能验证「坏的一份被删掉」。
            let delivered: URL
            if host == "github.com" {
                delivered = try self.write(Data("hello".utf8), named: "good-\(host).zip")
            } else {
                delivered = try self.write(Data("tampered".utf8), named: "bad-\(host).zip")
            }
            trace.record(host: host, file: delivered, request: request)
            return (delivered, self.response(for: request.url!, status: 200))
        }
        XCTAssertEqual(url, staging.appendingPathComponent("good-github.com.zip"))
        XCTAssertEqual(trace.hosts, Self.mirrors + ["github.com"])
        XCTAssertEqual(verifiedHosts.hosts, ["github.com"], "只有校验通过的源才算数")
        for host in Self.mirrors {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: staging.appendingPathComponent("bad-\(host).zip").path),
                "\(host) 上校验失败的下载必须被删除"
            )
        }
    }

    /// 用户取消后绝不能继续换镜像——那会把「不要了」变成四个源的重复下载。
    func testCancellationStopsAfterTheFirstAttempt() async {
        let trace = Trace()
        do {
            _ = try await UpdateArchiveDownloader.download(release: release) { request in
                trace.record(host: request.url?.host ?? "", file: self.goodFile, request: request)
                throw CancellationError()
            }
            XCTFail("应当抛出 CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(trace.hosts, ["xget.xi-xu.me"])
        }
    }

    /// 所有源都坏掉时，抛出的是最后一个真实的失败原因而不是内部占位值。
    func testExhaustedSourcesSurfaceTheLastRealFailure() async {
        do {
            _ = try await UpdateArchiveDownloader.download(release: release) { request in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("应当失败")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("应抛出 URLError，实际：\(error)")
        }
    }

    func testRefusesToInstallWhenNoSourceMatchesTheDigest() async throws {
        let trace = Trace()
        do {
            _ = try await UpdateArchiveDownloader.download(release: release) { request in
                let url = try self.write(Data("nonsense".utf8), named: "doomed-\(request.url?.host ?? "").zip")
                trace.record(host: request.url?.host ?? "", file: url, request: request)
                return (url, self.response(for: request.url!, status: 200))
            }
            XCTFail("全部源校验失败时必须报错")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .digestMismatch)
        }
        XCTAssertEqual(trace.hosts, Self.mirrors + ["github.com"], "四个源都试过才算走完")
        for url in trace.files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "校验不过的文件不能留在盘上：\(url)")
        }
    }

    private func runFailingMirrors(
        _ failures: @Sendable (String) async throws -> (URL, URLResponse)
    ) async throws -> Trace {
        let trace = Trace()
        _ = try await UpdateArchiveDownloader.download(release: release) { request in
            let host = request.url?.host ?? ""
            trace.record(host: host, file: self.goodFile, request: request)
            return try await failures(host)
        }
        return trace
    }
}
