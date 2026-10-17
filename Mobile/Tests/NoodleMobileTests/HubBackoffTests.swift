@testable import NoodleMobile
import Testing

/// How long the phone waits before trying a Hub again.
@Suite struct HubBackoffTests {
    @Test func eachWaitDoublesUpToHalfAMinuteAndStartsOverOnceConnected() {
        var backoff = HubBackoff(jitter: { 1 })
        let waits = (0..<7).map { _ in backoff.next() }
        #expect(waits == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
        backoff.reset()
        #expect(backoff.next() == .seconds(1))
    }

    @Test func eachWaitIsCutByUpToHalf() {
        var shortest = HubBackoff(jitter: { 0.5 })
        #expect(shortest.next() == .milliseconds(500))
        #expect(shortest.next() == .seconds(1))
        var random = HubBackoff()
        for full in [1, 2, 4, 8, 16, 30, 30] {
            let wait = random.next()
            #expect(wait >= .seconds(full) / 2 && wait <= .seconds(full))
        }
    }
}
