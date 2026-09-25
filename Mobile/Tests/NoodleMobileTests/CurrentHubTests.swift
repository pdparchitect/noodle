import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// Which of the joined Hubs the phone shows.
@MainActor @Suite struct CurrentHubTests {
    private let home = HubPairing(directory: URL(filePath: "/Hubs/home"), deviceName: "iPhone")
    private let friend = HubPairing(directory: URL(filePath: "/Hubs/friend"), deviceName: "iPhone")

    @Test func showsTheChosenHub() {
        #expect(CurrentHub.pick([home, friend], saved: CurrentHub.name(of: friend)) === friend)
    }

    @Test func showsTheFirstHubOnceTheChosenOneIsLeft() {
        #expect(CurrentHub.pick([home, friend], saved: "left") === home)
        #expect(CurrentHub.pick([], saved: "left") == nil)
    }

    @Test func aNewlyJoinedHubIsShown() {
        let before = [CurrentHub.name(of: home)]
        let after = [CurrentHub.name(of: home), CurrentHub.name(of: friend)]
        #expect(CurrentHub.joined(before: before, after: after) == CurrentHub.name(of: friend))
        #expect(CurrentHub.joined(before: after, after: before) == nil)
    }

    @Test func togetherShowsEveryHub() {
        #expect(CurrentHub.shown([home, friend], saved: CurrentHub.name(of: friend), together: true).map(CurrentHub.name) == ["home", "friend"])
        #expect(CurrentHub.shown([home, friend], saved: CurrentHub.name(of: friend), together: false).map(CurrentHub.name) == ["friend"])
        #expect(CurrentHub.shown([], saved: "", together: true).isEmpty)
    }
}
