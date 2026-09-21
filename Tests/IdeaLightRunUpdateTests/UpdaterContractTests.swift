import Foundation
import XCTest

@testable import IdeaLightRunUpdate

/// 主进程与更新助手之间只隔着一条 argv。契约两端在不同 target，
/// 一旦顺序/数量漂移，表现是「助手把某个目录当成了 app 来替换」。
final class UpdaterRequestTests: XCTestCase {
    private var request: UpdaterRequest {
        UpdaterRequest(
            parentPID: 4321,
            sourceApplication: URL(fileURLWithPath: "/tmp/stage/IdeaLightRun.app"),
            destinationApplication: URL(fileURLWithPath: "/Applications/IdeaLightRun.app"),
            stagingDirectory: URL(fileURLWithPath: "/tmp/stage"),
            helperDirectory: URL(fileURLWithPath: "/tmp/helper"),
            logURL: URL(fileURLWithPath: "/logs/update.log")
        )
    }

    func testSurvivesACommandLineRoundTrip() {
        let encoded = ["path/to/IdeaLightRunUpdater"] + request.processArguments
        XCTAssertEqual(UpdaterRequest(commandLineArguments: encoded), request)
    }

    func testArgumentSlotsAreInContractOrder() {
        XCTAssertEqual(request.processArguments, [
            "4321",
            "/tmp/stage/IdeaLightRun.app",
            "/Applications/IdeaLightRun.app",
            "/tmp/stage",
            "/tmp/helper",
            "/logs/update.log"
        ])
    }

    func testRejectsMalformedCommandLine() {
        let encoded = request.processArguments
        XCTAssertNil(UpdaterRequest(commandLineArguments: ["prog"] + encoded.dropLast()))
        XCTAssertNil(UpdaterRequest(commandLineArguments: ["prog"] + encoded + ["extra"]))
        XCTAssertNil(UpdaterRequest(commandLineArguments: ["prog", "notapid"] + encoded.dropFirst()))
        // pid 0 / 负数会被 kill(pid, 0) 解释成「发给整个进程组」，必须挡住
        XCTAssertNil(UpdaterRequest(commandLineArguments: ["prog", "0"] + encoded.dropFirst()))
        XCTAssertNil(UpdaterRequest(commandLineArguments: ["prog", "-1"] + encoded.dropFirst()))
    }

    func testRelaunchesTheReplacedBundleExecutableDirectly() {
        XCTAssertEqual(
            UpdaterRequest.directExecutableURL(for: URL(fileURLWithPath: "/Applications/IdeaLightRun.app")).path,
            "/Applications/IdeaLightRun.app/Contents/MacOS/IdeaLightRun"
        )
    }
}

final class UpdatePackageValidatorTests: XCTestCase {
    private let canonicalRequirement =
        #"identifier "com.idealightrun.app" and anchor apple generic and certificate leaf[subject.OU] = U8U443D7ZL"#

    func testParsesDesignatedRequirementFromCodesignOutput() {
        let output = """
        Executable=/Applications/IdeaLightRun.app/Contents/MacOS/IdeaLightRun
        Identifier=com.idealightrun.app
        CodeDirectory v=20500 flags=0x10000(runtime)
        designated => \(canonicalRequirement)
        """
        XCTAssertEqual(UpdatePackageValidator.parseDesignatedRequirement(from: output), canonicalRequirement)
        XCTAssertEqual(UpdatePackageValidator.parseDesignatedRequirement(from: "no requirement here"), "")
    }

    func testSHA256MatchesKnownVector() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lr-sha-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try UpdatePackageValidator.sha256(of: url),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    /// 身份判定比的是语义而不是文本：`anchor apple generic` 是 Apple 系统二进制
    /// 满足、而我们的 identifier 不满足的 requirement，正好用来证明判定有效。
    func testRequirementSatisfactionIsCheckedSemantically() {
        let echo = URL(fileURLWithPath: "/bin/echo")
        XCTAssertTrue(
            UpdatePackageValidator.satisfies("anchor apple generic", at: echo),
            "Apple 签名的系统二进制应被判定为满足 anchor apple generic"
        )
        XCTAssertFalse(
            UpdatePackageValidator.satisfies(canonicalRequirement, at: echo),
            "别人的 app 不能通过身份连续性检查"
        )
        XCTAssertFalse(UpdatePackageValidator.satisfies("", at: echo), "读不到 requirement 时一律判失败")
    }
}

/// 失败必须说清「哪一步、为什么、下一步做什么」，不能只剩「更新失败」。
final class UpdateFailureTests: XCTestCase {
    func testMapsEachErrorToItsOwnReason() {
        XCTAssertEqual(UpdateFailure(UpdateError.digestMismatch).title, "下载文件校验不通过")
        XCTAssertEqual(UpdateFailure(UpdateError.updaterHelperMissing).title, "缺少更新助手")
        XCTAssertTrue(UpdateFailure(UpdateError.updaterHelperMissing).suggestion.contains("Release"))
        XCTAssertTrue(
            UpdateFailure(UpdateError.currentVersionUnreadable("0.0.0-dev")).reason.contains("0.0.0-dev")
        )
    }

    func testUnknownErrorBecomesAFailureWithTheOriginalDetail() {
        let failure = UpdateFailure(URLError(.timedOut))
        XCTAssertEqual(failure.title, "连接失败")
        XCTAssertFalse(failure.reason.isEmpty)
    }

    func testCancellationIsReportedAsCancelledNotAsAnError() {
        XCTAssertEqual(UpdateFailure(CancellationError()).title, "已取消")
    }
}
