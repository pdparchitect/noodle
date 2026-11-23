import AppKit
import SwiftUI
import XCTest
import NoodleCore
import NoodleRuntimeSettings
import HubLink
@testable import Noodle

@MainActor final class MessageTableBubbleTests: HiddenViewTests {
    func testWrappedTableRowsReserveTheirFullHeight() {
        let text = "A selection of notebooks, coloured pencils, sketchbooks, watercolour paints, brushes, folders and drawing paper"
        let cell = host(Text(text).font(.system(size: 12.5).monospacedDigit())
            .lineLimit(3).frame(width: 260).fixedSize(horizontal: false, vertical: true))
        let rowCount = 4
        let table = MessageTable(header: ["Area", "Details"], alignments: [.leading, .leading],
                                 rows: (0..<rowCount).map { ["Row \($0)", text] })
        let grid = host(MessageTableGrid(table: table, sort: .constant(nil)))
        // Each row must contain its wrapped text plus the cell's vertical padding.
        XCTAssertGreaterThan(cell.fittingSize.height, 25)
        XCTAssertGreaterThanOrEqual(grid.fittingSize.height, CGFloat(rowCount) * (cell.fittingSize.height + 10))
    }

    func testShortTableCellsKeepCompactColumns() {
        let table = MessageTable(header: ["A", "B"], alignments: [.leading, .trailing], rows: [["1", "2"]])
        let grid = host(MessageTableGrid(table: table, sort: .constant(nil)))
        XCTAssertLessThan(grid.fittingSize.width, 150)
    }

    private func bubble(_ body: String, in f: StoreFixture) -> NSHostingView<some View> {
        let message = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id), body: body, delivery: .delivered)
        return host(MessageBubble(message: message, hasConversationBackground: false,
            selectedAttachmentID: .constant(nil), previewAttachment: { _, _ in }, showAgentProfile: nil)
            .padding().environment(f.store))
    }

    private func shows(_ text: String, in root: NSView) -> Bool {
        elements(root).contains { labels($0).contains(text) }
    }

    private let daily = "Daily numbers:\n\n| Day | Messages |\n|---|---|\n"
        + (1...24).map { "| Sep \($0) | \($0) |" }.joined(separator: "\n")
        + "\n\nWant this as a CSV?"

    func testTableRendersAsAFoldedSortableGridWithoutCountingAsLongText() async throws {
        let f = try fixture()
        let view = bubble(daily, in: f)
        let sort = try await control("Sort by Messages", in: view)
        XCTAssertEqual(elements(view).filter { self.matches("Sort by Day", node: $0) }.count, 1)
        XCTAssertTrue(hasControl("18 more rows", in: view))
        XCTAssertFalse(hasControl("Read full message", in: view))
        XCTAssertTrue(shows("Daily numbers:", in: view))
        XCTAssertTrue(shows("Want this as a CSV?", in: view))
        XCTAssertFalse(shows("| Day | Messages |", in: view))
        XCTAssertTrue(shows("Sep 6", in: view))
        XCTAssertFalse(shows("Sep 7", in: view))

        press(sort)
        press(try await control("Sort by Messages", in: view))
        // Rows animate into their new order.
        try await wait { self.shows("Sep 24", in: view) && !self.shows("Sep 1", in: view) }
        XCTAssertTrue(shows("Sep 19", in: view))
        XCTAssertFalse(shows("Sep 18", in: view))
    }

    func testMoreRowsOpensTheWholeTable() async throws {
        let f = try fixture()
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = bubble(daily, in: f)
        let window = try XCTUnwrap(view.window)
        window.setFrameOrigin(.init(x: 80, y: 80))
        window.orderFront(nil)
        press(try await control("18 more rows", in: view))
        var reader: NSView?
        try await wait {
            reader = NSApp.windows.filter { $0.isVisible && $0 !== window }
                .compactMap(\.contentView).first { self.shows("Sep 24", in: $0) }
            return reader != nil
        }
        let content = try XCTUnwrap(reader)
        XCTAssertTrue(shows("Sep 1", in: content))
        XCTAssertTrue(hasControl("Sort by Messages", in: content))
        press(try await control("Close", in: content))
        try await wait { content.window?.isVisible != true }
        window.close()
    }

    func testLongProseBesideATableStillFolds() async throws {
        let f = try fixture()
        let prose = (1...30).map { "Finding \($0)." }.joined(separator: "\n")
        let view = bubble(prose + "\n\n| A | B |\n|---|---|\n| 1 | 2 |", in: f)
        _ = try await control("Read full message", in: view)
        XCTAssertTrue(hasControl("Sort by A", in: view))
        XCTAssertFalse(hasControl("more rows", in: view))
    }

    func testMessagesWithoutTablesHaveNoTableControls() async throws {
        let f = try fixture()
        let view = bubble("Plain reply with a | pipe.\n---", in: f)
        // The dash line is drawn as a rule, so the sentence is the text that shows.
        try await wait { self.shows("Plain reply with a | pipe.", in: view) }
        XCTAssertFalse(elements(view).contains { labels($0).contains { $0.hasPrefix("Sort by") } })
    }

    func testALinkCardInANarrowWindowKeepsTheAvatarInPlace() async throws {
        let f = try fixture()
        func avatarX(_ body: String) async throws -> CGFloat {
            let message = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id), body: body, delivery: .delivered)
            let view = host(MessageBubble(message: message, hasConversationBackground: false,
                selectedAttachmentID: .constant(nil), previewAttachment: { _, _ in }, showAgentProfile: { _ in })
                .frame(width: 380).environment(f.store))
            let avatar = try await control("Show \(f.a.displayName)'s profile", in: view)
            return try XCTUnwrap((avatar.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue).minX
                - view.window!.frame.minX
        }
        let plain = try await avatarX("Done.")
        let card = try await avatarX("Done. https://mail.google.com/mail/u/0/#drafts")
        XCTAssertEqual(card, plain, accuracy: 0.5)
    }

    func testLinksTakeTheAccentColourLikeTheControlsAroundThem() {
        // The app's accent, or the one the person chose in System Settings, rather than the system's fixed link blue.
        let rendered = MessageMarkdownCache.render("Read [the advisory](https://example.com/advisory) first.")
        let link = rendered.runs.first { $0.link != nil }
        XCTAssertEqual(link?.foregroundColor, MessageMarkdownCache.linkColor)
        // The accent itself in both appearances, as other accent-coloured text has; not lightened in dark appearance.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var link = NSColor.clear, accent = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                link = NSColor(MessageMarkdownCache.linkColor).usingColorSpace(.sRGB)!
                accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            }
            XCTAssertEqual(link.redComponent, accent.redComponent, accuracy: 0.01, name.rawValue)
            XCTAssertEqual(link.greenComponent, accent.greenComponent, accuracy: 0.01, name.rawValue)
            XCTAssertEqual(link.blueComponent, accent.blueComponent, accuracy: 0.01, name.rawValue)
        }
        let prose = rendered.runs.first { $0.link == nil }
        XCTAssertNil(prose?.foregroundColor)
    }

    func testLinksAreLightenedOnlyAsMuchAsADarkWindowNeeds() {
        // A bright accent already reads on a dark window, so it is left as it is.
        let yellow = NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
        XCTAssertEqual(AccentLink.readable(yellow).usingColorSpace(.sRGB)!.blueComponent, yellow.blueComponent, accuracy: 0.01)
        // A deep one is lightened, but only until it reads, not by a fixed amount.
        let deepBlue = NSColor(srgbRed: 0.07, green: 0.32, blue: 0.8, alpha: 1)
        let lifted = AccentLink.readable(deepBlue).usingColorSpace(.sRGB)!
        XCTAssertGreaterThanOrEqual(AccentLink.luminance(lifted), AccentLink.readableLuminance)
        XCTAssertLessThan(AccentLink.luminance(lifted), AccentLink.readableLuminance + 0.05)
    }

    func testLinkButtonsDrawInTheSameAccentColourAsLinksInMessages() {
        // The system's link style keeps its own fixed blue whatever the accent; the accent link style draws in the colour
        // links in messages have.
        let accentLink = drawnColour(Button("Profiles") {}.buttonStyle(.accentLink))
        let systemLink = drawnColour(Button("Profiles") {}.buttonStyle(.link))
        var expected = NSColor.clear
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            expected = NSColor(MessageMarkdownCache.linkColor).usingColorSpace(.sRGB)!
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        XCTAssertLessThan(distance(accentLink, expected), distance(systemLink, expected), "\(accentLink), \(systemLink), \(expected)")
        XCTAssertLessThan(distance(accentLink, expected), 0.2, "\(accentLink) against \(expected)")
        // Disabled, it is dimmed as the system dims its own, still in the accent.
        let disabled = drawnColour(Button("Profiles") {}.buttonStyle(.accentLink).disabled(true))
        XCTAssertLessThan(disabled.alphaComponent, accentLink.alphaComponent, "\(disabled)")
        XCTAssertLessThan(distance(disabled, expected), distance(disabled, systemLink), "\(disabled)")
    }

    /// The most strongly coloured pixel of a button drawn on a dark window: the colour of its text.
    private func drawnColour<V: View>(_ button: V) -> NSColor {
        let view = host(button.padding(10).frame(width: 160, height: 40))
        view.window?.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var best = (score: -1.0, colour: NSColor.clear)
        for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
            // The faint edges of letters carry little of their colour.
            guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.2 else { continue }
            let score = colour.blueComponent - min(colour.redComponent, colour.greenComponent) + colour.alphaComponent
            if score > best.score { best = (score, colour) }
        } }
        return best.colour
    }

    func testAFlatToolIconDrawsTheLogoInInkOnTheTileWhicheverWayRoundItsColoursAre() {
        // A dark logo on a light tile, and a light logo on a dark one: either way the logo is the smaller part.
        for (background, logo) in [(CGFloat(1), CGFloat(0)), (0, 1)] {
            let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(gray: background, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.setFillColor(gray: logo, alpha: 1); context.fill(CGRect(x: 12, y: 12, width: 16, height: 16))
            let tile = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1), ink = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            let flat = NSBitmapImageRep(cgImage: FlatToolIcon.twoTone(context.makeImage()!, tile: tile, ink: ink)!)
            func grey(_ x: Int, _ y: Int) -> CGFloat {
                let px = Int(CGFloat(x) / 40 * CGFloat(flat.pixelsWide)), py = Int(CGFloat(y) / 40 * CGFloat(flat.pixelsHigh))
                return flat.colorAt(x: px, y: py)!.usingColorSpace(.sRGB)!.redComponent
            }
            XCTAssertEqual(grey(20, 20), 0.9, accuracy: 0.08, "the logo, from a \(background == 1 ? "light" : "dark") tile")
            XCTAssertEqual(grey(3, 3), 0.2, accuracy: 0.08, "the tile, from a \(background == 1 ? "light" : "dark") tile")
        }
    }

    func testHeadingsAreBoldLinesWithoutTheirHashes() {
        let rendered = MessageMarkdownCache.render("# Evidence\nThe logs.\n## Next steps\n#hashtag stays as written")
        XCTAssertEqual(String(rendered.characters), "Evidence\nThe logs.\nNext steps\n#hashtag stays as written")
        let bold = rendered.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(rendered[$0.range].characters) }
        XCTAssertEqual(bold, ["Evidence", "Next steps"])
        // Not inside code, where a # starts a comment.
        let code = MessageMarkdownCache.blocks("```\n# a comment\n```")
        guard case .code(let text) = code.first else { return XCTFail("\(code)") }
        XCTAssertEqual(text, "# a comment")
    }

    func testQuotesAndRulesBecomeBlocksOfTheirOwn() {
        let blocks = MessageMarkdownCache.blocks("The gateway said:\n> 550 **rejected**\n>\n> try later\nThen:\n\n---\n***\nAfter.")
        func describe(_ block: MessageBlock) -> String {
            switch block {
            case .text(let text): "text: " + String(text.characters)
            case .quote(let text): "quote: " + String(text.characters)
            case .rule: "rule"
            default: "other"
            }
        }
        XCTAssertEqual(blocks.map(describe), ["text: The gateway said:", "quote: 550 rejected\n\ntry later", "text: Then:", "rule", "rule", "text: After."])
        // The quote keeps its own formatting.
        if case .quote(let text) = blocks[1] {
            XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        }
        // A dash line inside code stays code.
        guard case .code(let code) = MessageMarkdownCache.blocks("```\n---\n```").first else { return XCTFail() }
        XCTAssertEqual(code, "---")
    }

    func testNoodleSplitsMessagesIntoTheSameParagraphsListsAndCodeAsPion() {
        let blocks = MessageMarkdownCache.blocks("Steps:\n- Revoke the session\n2) Reset the password\n\n```\nlet a = 1\n```")
        func describe(_ block: MessageBlock) -> String {
            switch block {
            case .text(let text): "text: " + String(text.characters)
            case .code(let code): "code: " + code
            case .list(let items): "list: " + items.map { "\($0.marker) \(String($0.text.characters))" }.joined(separator: " | ")
            case .quote(let text): "quote: " + String(text.characters)
            case .rule: "rule"
            }
        }
        XCTAssertEqual(blocks.map(describe), ["text: Steps:", "list: • Revoke the session | 2. Reset the password", "code: let a = 1"])
    }

    func testInlineCodeIsSmallerAndDimmerThanTheTextAroundIt() {
        let rendered = MessageMarkdownCache.render("Run `swift test` now.")
        let code = rendered.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code?.font, .system(size: 11.5, design: .monospaced))
        XCTAssertEqual(code?.foregroundColor, .primary.opacity(0.65))
        let prose = rendered.runs.first { $0.inlinePresentationIntent == nil }
        XCTAssertNil(prose?.font)
        XCTAssertNil(prose?.foregroundColor)
    }

    func testChangingTheLongMessageLayoutSplitsAnAlreadyRenderedMessage() throws {
        let f = try fixture()
        let message = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id),
                                  body: "One.\n\nTwo.\n\n| A |\n|---|\n| 1 |\n\nThree.\n\nFour.", delivery: .delivered)
        XCTAssertEqual(MessageMarkdownCache.shared.segments(message, layout: .together).count, 3)
        XCTAssertEqual(MessageMarkdownCache.shared.segments(message, layout: .paragraphs).count, 5)
        XCTAssertEqual(MessageMarkdownCache.shared.segments(message, layout: .together).count, 3)
    }

    func testParagraphLayoutShowsEachParagraphInItsOwnBubble() async throws {
        let f = try fixture()
        f.runtime.defaults.set(MessageTextLayout.paragraphs.rawValue, forKey: MessageTextLayout.defaultsKey)
        let message = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id),
                                  body: "Morning.\n\nAll quiet overnight.", delivery: .delivered)
        let view = host(MessageBubble(message: message, hasConversationBackground: false,
            selectedAttachmentID: .constant(nil), previewAttachment: { _, _ in }, showAgentProfile: nil)
            .padding().environment(f.store).defaultAppStorage(f.runtime.defaults))
        try await wait { self.shows("Morning.", in: view) }
        XCTAssertTrue(shows("All quiet overnight.", in: view))
    }

    func testNotificationsAndPreviewsLeaveTablesOut() throws {
        let f = try fixture()
        let body = "Here you go:\n\n| Day | Messages |\n|---|---|\n| Sep 1 | 4 |\n\nAll **quiet**."
        let message = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id), body: body, delivery: .delivered)
        // Notifications take plain text only, so the Markdown goes too.
        XCTAssertEqual(AgentNotifications.content(message: message, from: f.a, in: f.directA).body,
                       "Here you go:\nAll quiet.")
        let tableOnly = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id),
                                    body: "| A |\n|---|\n| 1 |", delivery: .delivered)
        XCTAssertEqual(AgentNotifications.content(message: tableOnly, from: f.a, in: f.directA).body, "Sent a table")

        _ = try f.repository.sendUserMessage(conversationID: f.directB.id, body: body)
        f.store.refreshTranscripts()
        XCTAssertEqual(f.store.preview(for: f.directB), "Here you go: All quiet.")
    }
}
