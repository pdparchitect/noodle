import Foundation
import NoodleCore
import NoodleSharing
import XCTest

@MainActor final class ShareFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-share-\(UUID())").resolvingSymlinksInPath()
    let destinations = [ShareDestination(id: UUID(), name: "Bot", isGroup: false), ShareDestination(id: UUID(), name: "Team", isGroup: true)]
    let inbox: SharedInbox
    let model: ShareComposerModel
    init() throws {
        inbox = SharedInbox(rootURL: root.appendingPathComponent("inbox"))
        try inbox.saveDestinations(destinations)
        model = ShareComposerModel(inbox: inbox)
    }
    func file(_ name: String, bytes: Data = Data("Shared bytes".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    func drafts() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: inbox.rootURL.appendingPathComponent("Drafts"), includingPropertiesForKeys: nil)
    }
    func load(_ inputs: [ShareInput]) async throws {
        model.load(inputs)
        try await waitUntil { !self.model.isLoading }
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Share loading did not finish"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func cleanUp() { model.cancel(); try? FileManager.default.removeItem(at: root) }
}
