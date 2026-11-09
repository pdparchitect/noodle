import Foundation
@testable import NoodleMobile
import SwiftUI
import Testing

/// Under your own message: one check when sent, two when delivered, the rest in words, as on the Mac.
@MainActor struct DeliveryCaptionTests {
    @Test func sentAndDeliveredAreCheckMarksAndTheRestStayWords() {
        #expect(DeliveryCaption.checks(for: "Sent") == 1)
        #expect(DeliveryCaption.checks(for: "Delivered") == 2)
        #expect(DeliveryCaption.checks(for: "Sending…") == nil)
        #expect(DeliveryCaption.checks(for: "Not delivered") == nil)
    }

    @Test func goingFromOneCheckToTwoMovesNothing() throws {
        func size(_ delivery: String) throws -> CGSize {
            let renderer = ImageRenderer(content: DeliveryCaption(delivery: delivery))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return CGSize(width: image.width, height: image.height)
        }
        #expect(try size("Sent") == size("Delivered"))
    }
}
