import XCTest
@testable import NoodleCore

final class TranscriptScrollMetricsTests: XCTestCase {
    func testShortConversationWithTitlebarInsetIsAlreadyAtBottom() {
        let metrics = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 300,
                                             viewportHeight: 800, topInset: 52, bottomInset: 0)
        XCTAssertEqual(metrics.offset, 0)
        XCTAssertTrue(metrics.isAtBottom)
    }

    func testLongConversationUsesBothInsets() {
        let top = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 2000,
                                         viewportHeight: 800, topInset: 52, bottomInset: 20)
        XCTAssertFalse(top.isAtBottom)
        let bottom = TranscriptScrollMetrics(contentOffset: 1220, contentHeight: 2000,
                                            viewportHeight: 800, topInset: 52, bottomInset: 20)
        XCTAssertTrue(bottom.isAtBottom)
        XCTAssertEqual(bottom.offset, 1272)
        let aboveBottom = TranscriptScrollMetrics(contentOffset: 1200, contentHeight: 2000,
                                                 viewportHeight: 800, topInset: 52, bottomInset: 20)
        XCTAssertFalse(aboveBottom.isAtBottom)
    }

    func testBottomToleranceAndOverscroll() {
        for offset: CGFloat in [1198, 1200, 1208] {
            XCTAssertTrue(TranscriptScrollMetrics(contentOffset: offset, contentHeight: 2000,
                                                  viewportHeight: 800, topInset: 0, bottomInset: 0).isAtBottom)
        }
        XCTAssertEqual(TranscriptScrollMetrics(contentOffset: -70, contentHeight: 2000,
                                               viewportHeight: 800, topInset: 52, bottomInset: 0).offset, 0)
    }

    func testGrowingConversationBecomesScrollableWithoutChangingOffset() {
        let short = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 300,
                                           viewportHeight: 800, topInset: 52, bottomInset: 0)
        let long = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 2000,
                                          viewportHeight: 800, topInset: 52, bottomInset: 0)
        XCTAssertTrue(short.isAtBottom)
        XCTAssertFalse(long.isAtBottom)
        XCTAssertEqual(short.offset, long.offset)
    }
}
