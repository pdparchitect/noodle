import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class PatchReviewTests: XCTestCase {
    private let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,3 +1,4 @@ struct App {
         let name: String
    +    let version: Int
         let build: Int
         var title: String
    diff --git a/README.md b/README.md
    index 3333333..4444444 100644
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -# App
    +# The App

    """

    private func fixture() throws -> StoreFixture {
        let fixture = try StoreFixture()
        addTeardownBlock { @MainActor in fixture.cleanUp() }
        return fixture
    }

    private func attachment(_ text: String, named name: String = "change.patch", in f: StoreFixture) throws -> ConversationAttachment {
        try f.repository.importAttachment(data: Data(text.utf8), originalFilename: name, into: f.directA.id,
                                          mediaType: "application/octet-stream")
    }

    func testOnlyAFileThatReadsAsAPatchOpensInAReview() throws {
        let f = try fixture()
        let patch = try attachment(diff, in: f)
        XCTAssertTrue(patch.isPatchFile)
        XCTAssertEqual(PatchCache.patchNow(at: f.store.attachmentFileURL(patch))?.files.count, 2)

        // Named like a patch, but Quick Look shows it as the text it is.
        let notes = try attachment("Remember to review the patch.", named: "notes.diff", in: f)
        XCTAssertTrue(notes.isPatchFile)
        XCTAssertNil(PatchCache.patchNow(at: f.store.attachmentFileURL(notes)))

        let text = try attachment(diff, named: "change.txt", in: f)
        XCTAssertFalse(text.isPatchFile)
    }

    func testViewedFilesFoldAwayAndAreRemembered() throws {
        let f = try fixture()
        let attachment = try attachment(diff, in: f)
        let patch = try XCTUnwrap(Patch(diff))
        var saved: [Set<String>] = []
        let model = PatchReviewModel(patch: patch, attachment: attachment, viewed: []) {
            saved.append($0)
            f.store.saveViewedPatchFiles($0, for: attachment)
        }
        model.toggle("README.md")
        model.select(path: "README.md", hunk: 0, line: 1, extending: false)
        model.setViewed("README.md", true)
        XCTAssertEqual(model.viewed, ["README.md"])
        XCTAssertFalse(model.expanded.contains("README.md"))
        XCTAssertNil(model.selection)
        XCTAssertEqual(saved, [["README.md"]])
        XCTAssertEqual(f.store.viewedPatchFiles(attachment), ["README.md"])
        XCTAssertEqual(PatchReviewStore(fileURL: f.repository.rootURL.appendingPathComponent("patch-reviews.json")).viewed(attachment),
                       ["README.md"])

        model.setViewed("README.md", false)
        XCTAssertEqual(f.store.viewedPatchFiles(attachment), [])
    }

    func testACommentQuotesTheSelectedLinesOfItsPatch() throws {
        let f = try fixture()
        let attachment = try attachment(diff, in: f)
        let patch = try XCTUnwrap(Patch(diff))
        let model = PatchReviewModel(patch: patch, attachment: attachment, viewed: []) { _ in }
        XCTAssertNil(model.selectedQuote)

        model.select(path: "Sources/App.swift", hunk: 0, line: 1, extending: false)
        model.select(path: "Sources/App.swift", hunk: 0, line: 2, extending: true)
        XCTAssertTrue(model.isSelected(path: "Sources/App.swift", hunk: 0, line: 2))
        XCTAssertFalse(model.isSelected(path: "Sources/App.swift", hunk: 0, line: 0))
        let quote = try XCTUnwrap(model.selectedQuote)
        XCTAssertEqual(quote, "Sources/App.swift:2-3\n+    let version: Int\n     let build: Int")

        // Saved as any other annotation: it waits in the composer and names the patch as its source.
        let note = AttachmentAnnotation(source: attachment, quote: quote, comment: "Should this be optional?")
        try f.store.saveAnnotation(note, content: AnnotationContent.data(for: note, snapshot: nil), source: attachment)
        let saved = try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last?.annotation)
        XCTAssertEqual(saved.sourceAttachmentID, attachment.id)
        XCTAssertEqual(saved.quote, quote)
        XCTAssertEqual(patch.place(of: quote)?.line, 2)

        // Selecting one line, then the same line again, lets go of it.
        model.select(path: "README.md", hunk: 0, line: 0, extending: true)
        XCTAssertEqual(model.selection?.lines, 0...0)
        model.select(path: "README.md", hunk: 0, line: 0, extending: false)
        XCTAssertNil(model.selection)
    }

    /// A drag selects every line it passes over, in either direction, and stays in the hunk it started in.
    func testADragSelectsTheLinesItPassesOverWithinItsHunk() throws {
        let f = try fixture()
        let patch = try XCTUnwrap(Patch(diff))
        let model = PatchReviewModel(patch: patch, attachment: try attachment(diff, in: f), viewed: []) { _ in }
        // Four lines of a hunk, with a comment shown under the second.
        let frames = [0: CGRect(x: 0, y: 100, width: 600, height: 16), 1: CGRect(x: 0, y: 116, width: 600, height: 16),
                      2: CGRect(x: 0, y: 172, width: 600, height: 16), 3: CGRect(x: 0, y: 188, width: 600, height: 16)]
        XCTAssertEqual(PatchReviewModel.line(at: 120, in: frames), 1)
        XCTAssertEqual(PatchReviewModel.line(at: 140, in: frames), 1, "Over a comment, the nearest line")
        XCTAssertEqual(PatchReviewModel.line(at: 40, in: frames), 0, "Above the hunk, its first line")
        XCTAssertEqual(PatchReviewModel.line(at: 900, in: frames), 3, "Below it, its last line")
        XCTAssertNil(PatchReviewModel.line(at: 120, in: [:]))

        model.drag(path: "Sources/App.swift", hunk: 0, from: 3, to: 1, extending: false)
        XCTAssertEqual(model.selection?.lines, 1...3)
        XCTAssertTrue(model.isSelected(path: "Sources/App.swift", hunk: 0, line: 2))
        XCTAssertFalse(model.isSelected(path: "Sources/App.swift", hunk: 0, line: 0))
        let lines = patch.files[0].hunks[0].lines
        XCTAssertEqual(model.selectedQuote, Patch.quote(Array(lines[1...3]), in: "Sources/App.swift"))
        XCTAssertEqual(patch.place(of: try XCTUnwrap(model.selectedQuote))?.line, 3, "Shown under the last line it quotes")

        // A new drag starts over; with Shift it extends the selection from where it was anchored.
        model.drag(path: "Sources/App.swift", hunk: 0, from: 0, to: 1, extending: false)
        XCTAssertEqual(model.selection?.lines, 0...1)
        model.drag(path: "Sources/App.swift", hunk: 0, from: 2, to: 3, extending: true)
        XCTAssertEqual(model.selection?.lines, 0...3)
        model.drag(path: "README.md", hunk: 0, from: 1, to: 0, extending: true)
        XCTAssertEqual(model.selection, .init(path: "README.md", hunk: 0, anchor: 1, head: 0), "Shift does not reach across hunks")

        // A click still selects one line, and Shift-click extends it.
        model.select(path: "Sources/App.swift", hunk: 0, line: 2, extending: false)
        XCTAssertEqual(model.selection?.lines, 2...2)
        model.select(path: "Sources/App.swift", hunk: 0, line: 0, extending: true)
        XCTAssertEqual(model.selection?.lines, 0...2)
    }

    /// With no lines selected, a comment is on the whole patch, as on any other attachment.
    func testWithNoLinesSelectedACommentIsOnTheWholePatch() throws {
        let f = try fixture()
        let attachment = try attachment(diff, in: f)
        let model = PatchReviewModel(patch: try XCTUnwrap(Patch(diff)), attachment: attachment, viewed: []) { _ in }
        XCTAssertNil(model.selectedQuote)

        let note = AttachmentAnnotation(source: attachment, quote: model.selectedQuote, comment: "Split this into two commits.")
        XCTAssertTrue(note.isValid)
        try f.store.saveAnnotation(note, content: AnnotationContent.data(for: note, snapshot: nil), source: attachment)
        let saved = try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last?.annotation)
        XCTAssertEqual(saved.sourceAttachmentID, attachment.id)
        XCTAssertNil(saved.quote)
        XCTAssertNil(saved.region)
    }

    /// Add Annotation in a review comments on the whole patch or on the selected lines, and keeps working after a
    /// comment is closed unsaved and after the review is closed and opened again. Annotate Region is the review's too.
    func testTheReviewCommentsAgainAfterACommentIsClosedUnsaved() throws {
        let f = try fixture()
        let attachment = try attachment(diff, in: f)
        let patch = try XCTUnwrap(Patch(diff))
        let windows = AttachmentWindows()
        windows.open(attachment, patch: patch, store: f.store)
        var panel = try XCTUnwrap(windows.frontmost)
        defer { windows.frontmost?.close() }

        func shortcut(_ key: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                           windowNumber: panel.windowNumber, context: nil, characters: key.uppercased(),
                                           charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        }
        func views(_ view: NSView?) -> [NSView] { view.map { [$0] + $0.subviews.flatMap(views) } ?? [] }
        func everyView() -> [NSView] { NSApp.windows.filter(\.isVisible).flatMap { views($0.contentView) } }
        func labels() -> [String] { everyView().compactMap { ($0 as? NSTextField)?.stringValue } }
        // The comment's popover points from a window of its own, laid over the review.
        func isCommenting() -> Bool { !(panel.childWindows ?? []).isEmpty }
        func comment() throws { XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("a", code: 0))) }
        func closeComment() throws {
            let close = try XCTUnwrap(everyView().compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "Cancel annotation" })
            close.performClick(nil)
            let end = Date().addingTimeInterval(3)
            while isCommenting(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertFalse(isCommenting())
        }

        try comment()
        XCTAssertTrue(isCommenting(), "With no lines selected, the comment is on the whole patch")
        XCTAssertTrue(labels().contains("Whole attachment · no selected text"))
        try comment()
        try closeComment()

        try XCTUnwrap(windows.model(for: attachment)).select(path: "README.md", hunk: 0, line: 1, extending: false)
        try comment()
        XCTAssertTrue(isCommenting(), "A comment closed unsaved does not stop the next one")
        XCTAssertTrue(labels().contains { $0.hasPrefix("README.md:1") })

        panel.close()
        windows.open(attachment, patch: patch, store: f.store)
        panel = try XCTUnwrap(windows.frontmost)
        try comment()
        XCTAssertTrue(isCommenting(), "Nor does closing the review with a comment open")
        try closeComment()

        XCTAssertTrue(panel.performKeyEquivalent(with: try shortcut("r", code: 15)))
        // Closed before its picture is taken, which needs Screen Recording access.
        panel.close()
    }
}
