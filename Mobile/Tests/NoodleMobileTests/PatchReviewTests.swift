import Foundation
import HubLink
@testable import NoodleMobile
import NoodlePatch
import Testing

/// A .patch or .diff file opens in a review, whose Viewed ticks this phone remembers.
@MainActor @Suite struct PatchReviewTests {
    private let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,2 +1,3 @@
     let name: String
    +let version: Int
     let build: Int
    diff --git a/Sources/Views/Card.swift b/Sources/Views/Card.swift
    --- a/Sources/Views/Card.swift
    +++ b/Sources/Views/Card.swift
    @@ -1 +1 @@
    -struct Card {}
    +struct Card: View {}
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -# App
    +# The App

    """

    private let bot = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Wren", provider: "claude"),
                              createdAt: Date(timeIntervalSince1970: 0))

    private func file(_ name: String, mediaType: String = "application/octet-stream", voice: Bool = false,
                      url: String? = nil) -> LinkAttachment {
        LinkAttachment(id: UUID(), filename: name, mediaType: mediaType, byteCount: 1,
                       voice: voice ? LinkVoice(transcript: nil, duration: 1, waveform: [], localeIdentifier: nil) : nil,
                       url: url.flatMap(URL.init(string:)))
    }

    @Test func patchesAreToldByNameOrMediaType() {
        #expect(file("change.patch").isPatchFile)
        #expect(file("CHANGE.DIFF").isPatchFile)
        #expect(file("change", mediaType: "text/x-patch").isPatchFile)
        #expect(!file("notes.txt", mediaType: "text/plain").isPatchFile)
        #expect(!file("change.patch", voice: true).isPatchFile)
        #expect(!file("change.patch", url: "https://example.com/change.patch").isPatchFile)
    }

    @Test func filesAreGroupedByFolderFilteredAndHiddenOnceViewed() throws {
        let model = PatchReviewModel(patch: try #require(Patch(diff)), viewed: []) { _ in }
        #expect(model.folders.map(\.path) == ["", "Sources", "Sources/Views"])
        #expect(model.folders.map { $0.files.map(\.name) } == [["README.md"], ["App.swift"], ["Card.swift"]])

        model.filter = "card"
        #expect(model.folders.map(\.path) == ["Sources/Views"])
        model.filter = ""

        model.setViewed("README.md", true)
        #expect(model.viewedCount == 1)
        #expect(model.folders.first?.viewed == 1)
        model.hidesViewed = true
        #expect(model.folders.map(\.path) == ["Sources", "Sources/Views"])
    }

    @Test func viewedFilesAreRememberedOnThisPhonePerAttachment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        let patch = file("change.patch"), other = file("other.patch")
        let thread = HubThread.bot(bot)
        let model = PatchReviewModel(patch: try #require(Patch(diff)), viewed: chats.viewedPatchFiles(patch, in: thread)) {
            chats.saveViewedPatchFiles($0, for: patch, in: thread)
        }
        model.setViewed("Sources/App.swift", true)
        model.setViewed("README.md", true)
        model.setViewed("README.md", false)

        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.viewedPatchFiles(patch, in: thread) == ["Sources/App.swift"])
        #expect(relaunched.viewedPatchFiles(other, in: thread) == [])
    }
}
