import Foundation
import XCTest

@testable import IdeaLightRunUpdate

/// 版本比较与发布元数据解析：走错一步就是「把用户的 app 换成别的版本」。
final class SoftwareVersionTests: XCTestCase {
    func testParsesReleaseTagsAndRejectsNonNumeric() {
        XCTAssertEqual(SoftwareVersion("v0.1.6")?.description, "0.1.6")
        XCTAssertEqual(SoftwareVersion("0.1.6")?.description, "0.1.6")
        // 开发构建 / 占位值必须判为不可比较，而不是当成 0
        XCTAssertNil(SoftwareVersion("0.0.0-dev"))
        XCTAssertNil(SoftwareVersion("development"))
        XCTAssertNil(SoftwareVersion(""))
        XCTAssertNil(SoftwareVersion("1..2"))
        XCTAssertNil(SoftwareVersion("1.2-beta"))
    }

    func testComparesNumericallyPerComponentNotLexically() {
        XCTAssertLessThan(SoftwareVersion("1.9.9")!, SoftwareVersion("1.10.0")!)
        XCTAssertLessThan(SoftwareVersion("0.1.5")!, SoftwareVersion("0.1.6")!)
        XCTAssertLessThan(SoftwareVersion("0.9.0")!, SoftwareVersion("0.10.0")!)
        XCTAssertGreaterThan(SoftwareVersion("2.0.0")!, SoftwareVersion("1.99.99")!)
    }

    func testTrailingZerosDoNotCreateADifferentVersion() {
        XCTAssertEqual(SoftwareVersion("1.10"), SoftwareVersion("1.10.0"))
        XCTAssertEqual(Set([SoftwareVersion("1.10.0")!, SoftwareVersion("1.10")!]).count, 1)
    }

    func testIsNewerFailsClosedOnUnreadableCurrentVersion() {
        let release = SoftwareRelease(
            version: SoftwareVersion("0.2.0")!,
            tagName: "v0.2.0",
            releaseNotes: "",
            archiveURL: URL(string: "https://github.com/misswell/IdeaLightRun/releases/download/v0.2.0/IdeaLightRun-0.2.0-universal.zip")!,
            sha256: String(repeating: "a", count: 64)
        )
        XCTAssertFalse(release.isNewer(than: "0.0.0-dev"), "读不出当前版本时不能提示可更新")
        XCTAssertFalse(release.isNewer(than: "0.2.0"))
        XCTAssertTrue(release.isNewer(than: "0.1.9"))
    }
}

final class SoftwareReleaseDecodingTests: XCTestCase {
    private let expectedName = UpdateIdentity.archiveName(version: "0.1.6")

    private func json(_ assets: [String: String?], draft: Bool = false, prerelease: Bool = false, tag: String = "v0.1.6") -> Data {
        let assetList = assets.map { name, digest -> String in
            let digestField = digest.map { "\"digest\":\"sha256:\($0)\"" } ?? "\"digest\":null"
            return """
            {"name":"\(name)","browser_download_url":"https://github.com/misswell/IdeaLightRun/releases/download/v0.1.6/\(name)",\(digestField)}
            """
        }
        let body = """
        {"tag_name":"\(tag)","body":"notes","draft":\(draft),"prerelease":\(prerelease),
         "assets":[\(assetList.joined(separator: ","))]}
        """
        return Data(body.utf8)
    }

    private let digest = String(repeating: "f", count: 64)

    func testPicksTheVersionedUniversalZipAmongOtherAssets() throws {
        let release = try SoftwareRelease.decodeGitHubResponse(json([
            "SHA256SUMS.txt": digest,
            expectedName: digest
        ]))
        XCTAssertEqual(release.version, SoftwareVersion("0.1.6"))
        XCTAssertEqual(release.tagName, "v0.1.6")
        XCTAssertEqual(release.releaseNotes, "notes")
        XCTAssertEqual(release.sha256, digest)
        XCTAssertEqual(release.archiveURL.lastPathComponent, expectedName)
    }

    func testIgnoresDraftAndPrerelease() {
        XCTAssertThrowsError(try SoftwareRelease.decodeGitHubResponse(json([expectedName: digest], draft: true))) {
            XCTAssertEqual($0 as? UpdateError, .invalidRelease)
        }
        XCTAssertThrowsError(try SoftwareRelease.decodeGitHubResponse(json([expectedName: digest], prerelease: true))) {
            XCTAssertEqual($0 as? UpdateError, .invalidRelease)
        }
        XCTAssertThrowsError(try SoftwareRelease.decodeGitHubResponse(json([expectedName: digest], tag: "v0.1.6-beta"))) {
            XCTAssertEqual($0 as? UpdateError, .invalidRelease)
        }
    }

    /// 没有 digest 就没有可信来源：宁可报「没有可安装的包」，也不能裸下 zip。
    func testRejectsAssetWithoutVerifiableDigest() {
        let payloads: [Data] = [json([expectedName: nil]), json(["IdeaLightRun-0.1.5-universal.zip": digest]), json([expectedName: "nothex"])]
        for payload in payloads {
            XCTAssertThrowsError(try SoftwareRelease.decodeGitHubResponse(payload)) {
                XCTAssertEqual($0 as? UpdateError, .missingVerifiedArchive)
            }
        }
    }

    func testRejectsNonHTTPSDownloadURL() {
        let body = """
        {"tag_name":"v0.1.6","body":"","draft":false,"prerelease":false,
         "assets":[{"name":"\(expectedName)","browser_download_url":"http://github.com/x/\(expectedName)","digest":"sha256:\(digest)"}]}
        """
        XCTAssertThrowsError(try SoftwareRelease.decodeGitHubResponse(Data(body.utf8))) {
            XCTAssertEqual($0 as? UpdateError, .missingVerifiedArchive)
        }
    }

    /// API 被限流时的兜底：从 expanded_assets 的 HTML 里同样要拿到 sha256。
    func testParsesExpandedAssetsHTML() throws {
        let html = """
        <div><a href="/misswell/IdeaLightRun/releases/download/v0.1.6/SHA256SUMS.txt">SHA256SUMS.txt</a></div>
        <div><a href="/misswell/IdeaLightRun/releases/download/v0.1.6/\(expectedName)">\(expectedName)</a>
        <span>sha256:\(digest.uppercased())</span></div>
        """
        let release = try SoftwareRelease.decodeGitHubAssetsHTML(Data(html.utf8), tagName: "v0.1.6")
        XCTAssertEqual(release.archiveURL.absoluteString,
                       "https://github.com/misswell/IdeaLightRun/releases/download/v0.1.6/\(expectedName)")
        XCTAssertEqual(release.sha256, digest)
        XCTAssertEqual(release.releaseNotes, "")
    }

    func testExpandedAssetsHTMLWithoutDigestIsRejected() {
        let html = "<a href=\"/misswell/IdeaLightRun/releases/download/v0.1.6/\(expectedName)\">x</a>"
        XCTAssertThrowsError(try SoftwareRelease.decodeGitHubAssetsHTML(Data(html.utf8), tagName: "v0.1.6")) {
            XCTAssertEqual($0 as? UpdateError, .missingVerifiedArchive)
        }
    }
}

/// 更新通道靠字面量对齐：仓库名、产物名、Team ID 任一处改了没同步，
/// 表现是「永远提示无更新」或「永远校验失败」。这里用脚本原文把它们钉住。
final class UpdateIdentityTests: XCTestCase {
    private var repoRoot: URL {
        // #filePath = <root>/Tests/IdeaLightRunUpdateTests/<本文件>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testArchiveNameMatchesWhatTheReleasePipelineUploads() throws {
        let workflow = try read(".github/workflows/release.yml")
        let archiveAssignment = ##"archive="dist/IdeaLightRun-${VERSION}-universal.zip""##
        XCTAssertTrue(workflow.contains(archiveAssignment),
                      "release.yml 的产物名变了，要同步 UpdateIdentity.archiveName")
        let distributable = try read("scripts/distribute-app.sh")
        XCTAssertTrue(distributable.contains(##"ZIP="$DIST/IdeaLightRun-${VERSION}-universal.zip""##))
        XCTAssertEqual(UpdateIdentity.archiveName(version: "9.9.9"), "IdeaLightRun-9.9.9-universal.zip")
    }

    func testBundleIdentityMatchesTheBuiltPlist() throws {
        let buildScript = try read("scripts/build-app.sh")
        XCTAssertTrue(buildScript.contains("<string>\(UpdateIdentity.bundleIdentifier)</string>"),
                      "Info.plist 的 bundle id 与 UpdateIdentity 不一致，校验会把自己判成别人的 app")
        XCTAssertTrue(buildScript.contains("<string>\(UpdateIdentity.executableName)</string>"))
        XCTAssertTrue(buildScript.contains(UpdateIdentity.developerTeamIdentifier),
                      "签名 Team 与更新校验里钉死的 Team 必须同源")
    }

    func testBundledUpdaterLivesWhereTheValidatorLooks() throws {
        let buildScript = try read("scripts/build-app.sh")
        XCTAssertTrue(buildScript.contains("Contents/MacOS/\(UpdateIdentity.updaterExecutableName)"),
                      "打包脚本必须把更新助手放进 Contents/MacOS，否则每个新版本都会被自己判为不完整")
    }
}
