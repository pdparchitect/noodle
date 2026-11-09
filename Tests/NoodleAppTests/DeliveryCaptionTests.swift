import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// The caption under your own message: one check when sent, two when delivered, the other two states in words.
@MainActor final class DeliveryCaptionTests: HiddenViewTests {
    func testSentAndDeliveredAreCheckMarksAndTheOthersStayWords() {
        XCTAssertNil(DeliveryCaption(delivery: .saved).checks)
        XCTAssertEqual(DeliveryCaption(delivery: .queued).checks, 1)
        XCTAssertEqual(DeliveryCaption(delivery: .delivered).checks, 2)
        XCTAssertNil(DeliveryCaption(delivery: .failed).checks)
    }

    func testEveryStateStillSaysItsWordsToVoiceOver() {
        let expected: [(MessageDelivery, String)] = [(.saved, "Saved"), (.queued, "Sent"), (.delivered, "Delivered"), (.failed, "Not delivered")]
        for (delivery, label) in expected {
            XCTAssertEqual(DeliveryCaption(delivery: delivery).label, label)
            let caption = host(DeliveryCaption(delivery: delivery))
            XCTAssertTrue(elements(caption).contains { labels($0).contains(label) }, "VoiceOver says \(label)")
        }
    }

    func testTheHoverHelpSaysSentAndDelivered() {
        for (delivery, label) in [(MessageDelivery.queued, "Sent"), (.delivered, "Delivered")] {
            let caption = host(DeliveryCaption(delivery: delivery))
            XCTAssertTrue(elements(caption).contains { (attribute($0, .help) as? String) == label }, "The tooltip says \(label)")
        }
    }

    func testGoingFromOneCheckToTwoMovesNothing() {
        XCTAssertEqual(host(DeliveryCaption(delivery: .queued)).fittingSize, host(DeliveryCaption(delivery: .delivered)).fittingSize)
    }

    func testTheChecksTakeTheCaptionsHeight() {
        XCTAssertEqual(host(DeliveryCaption(delivery: .saved)).fittingSize.height, host(DeliveryCaption(delivery: .queued)).fittingSize.height)
    }

    func testOneCheckAndTwoChecksLookDifferent() throws {
        func drawn(_ delivery: MessageDelivery) throws -> Data {
            let renderer = ImageRenderer(content: DeliveryCaption(delivery: delivery).foregroundStyle(.black).background(.white))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            return try XCTUnwrap(image.dataProvider?.data as Data?)
        }
        XCTAssertNotEqual(try drawn(.queued), try drawn(.delivered))
    }
}
