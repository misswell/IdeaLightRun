import XCTest
@testable import IdeaLightRunCore

/// 控制台跟随策略：停在底部时跟随新日志；向上回看时不打断阅读。
final class LogScrollFollowTests: XCTestCase {
    func testFollowsWhenExactlyAtBottom() {
        XCTAssertTrue(LogScrollFollow.isAtBottom(
            originY: 500,
            visibleHeight: 500,
            documentHeight: 1000
        ))
    }

    func testFollowsWhenWithinToleranceOfBottom() {
        XCTAssertTrue(LogScrollFollow.isAtBottom(
            originY: 494,
            visibleHeight: 500,
            documentHeight: 1000
        ))
    }

    func testDoesNotFollowWhenReadingEarlierLines() {
        XCTAssertFalse(LogScrollFollow.isAtBottom(
            originY: 480,
            visibleHeight: 500,
            documentHeight: 1000
        ))
    }

    func testContentShorterThanViewportAlwaysFollows() {
        XCTAssertTrue(LogScrollFollow.isAtBottom(
            originY: 0,
            visibleHeight: 500,
            documentHeight: 300
        ))
        XCTAssertTrue(LogScrollFollow.isAtBottom(
            originY: -20,
            visibleHeight: 500,
            documentHeight: 300
        ), "容器不足一屏时的弹性回弹不能关掉跟随")
    }

    func testOverscrollAtBottomKeepsFollowing() {
        XCTAssertTrue(LogScrollFollow.isAtBottom(
            originY: 510,
            visibleHeight: 500,
            documentHeight: 1000
        ))
    }
}
