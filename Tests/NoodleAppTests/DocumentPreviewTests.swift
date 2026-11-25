import AppKit
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class DocumentPreviewTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let fixture = try StoreFixture()
        addTeardownBlock { @MainActor in fixture.cleanUp() }
        return fixture
    }

    private func views(_ view: NSView?) -> [NSView] { view.map { [$0] + $0.subviews.flatMap(views) } ?? [] }

    /// Opens `name` as a conversation does, and returns the window it opened in, if any.
    private func open(_ text: String, named name: String, mediaType: String = "application/octet-stream",
                      in f: StoreFixture, windows: AttachmentWindows) throws -> NSWindow? {
        let attachment = try f.repository.importAttachment(data: Data(text.utf8), originalFilename: name, into: f.directA.id,
                                                           mediaType: mediaType)
        let opening = AttachmentOpening(preview: AttachmentPreviewController(), capture: ScreenCapturePreviewController(),
                                        windows: windows)
        opening.open(attachment, among: [attachment], host: f.store)
        let window = windows.frontmost
        addTeardownBlock { @MainActor in window?.close() }
        return window
    }

    /// Markdown and shaders open in a window of their own, not Quick Look, showing the file rendered with Preview and
    /// as it is written with Source.
    func testMarkdownAndShadersOpenInTheirOwnWindowWithPreviewAndSource() throws {
        let f = try fixture()
        for (name, source, kind) in [("notes.md", "# Title\n\nSome **bold** text.", "Markdown"),
                                     ("waves.metal", "#include <metal_stdlib>\nusing namespace metal;\n", "Shader")] {
            let windows = AttachmentWindows()
            let window = try XCTUnwrap(try open(source, named: name, in: f, windows: windows), name)
            XCTAssertEqual(window.title, name)
            let labels = views(window.contentView).compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(labels.contains(kind), "\(labels)")

            let control = try XCTUnwrap(views(window.contentView).compactMap { $0 as? NSSegmentedControl }.first, name)
            XCTAssertEqual((0..<control.segmentCount).map { control.label(forSegment: $0) }, ["Preview", "Source"])
            XCTAssertEqual(control.selectedSegment, 0)
            func shownSource() -> String? {
                window.contentView?.layoutSubtreeIfNeeded()
                return views(window.contentView).compactMap { ($0 as? NSTextView)?.string }.first { $0 == source }
            }
            XCTAssertNil(shownSource())

            control.selectedSegment = 1
            XCTAssertTrue(control.sendAction(control.action, to: control.target))
            let end = Date().addingTimeInterval(3)
            while shownSource() == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertEqual(shownSource(), source, name)
        }
    }

    /// Other text files keep opening in Quick Look.
    func testOtherFilesDoNotOpenAsDocuments() throws {
        let f = try fixture()
        XCTAssertNil(try open("Plain notes.", named: "notes.txt", mediaType: "text/plain", in: f, windows: AttachmentWindows()))
    }
}
