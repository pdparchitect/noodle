import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// The native chat composer hosted in a window that is never ordered onscreen.
@MainActor final class ScrollableComposerTests: HiddenViewTests {
    /// SwiftUI measures the composer at several speculative widths. Measuring
    /// must not reflow the live editor, scroll it or move the caret.
    func testMeasuringHeightLeavesTheLiveEditorAlone() async throws {
        let (model, composer) = try await mount()
        model.focused = true
        try await wait { composer.window?.firstResponder === composer.editor }
        XCTAssertGreaterThan(composer.editor.frame.height, composer.contentSize.height * 2,
            "A long draft must extend past the visible composer")
        composer.editor.setSelectedRange(NSRange(location: 120, length: 0))
        composer.contentView.scroll(to: NSPoint(x: 0, y: 150))
        composer.reflectScrolledClipView(composer.contentView)
        let frame = composer.editor.frame
        let container = try XCTUnwrap(composer.editor.textContainer).containerSize
        let viewport = composer.contentView.bounds
        let selection = composer.editor.selectedRange()
        for width in [CGFloat(1), 150, 700, composer.contentSize.width] {
            _ = composer.fittingHeight(width: width)
            XCTAssertEqual(composer.editor.textContainer?.containerSize, container, "Measuring at \(width) reflowed the editor")
            XCTAssertEqual(composer.editor.frame, frame, "Measuring at \(width) resized the editor")
            XCTAssertEqual(composer.contentView.bounds, viewport, "Measuring at \(width) scrolled the draft")
            XCTAssertEqual(composer.editor.selectedRange(), selection, "Measuring at \(width) moved the caret")
        }
    }

    /// An empty draft, one character and one line of text all use the same
    /// height; a real line break grows the composer, which stops growing at six
    /// lines, and switching to a chat with a short draft shrinks it again.
    func testHeightFollowsTheDraftUpToSixLines() async throws {
        let (model, composer) = try await mount()
        let long = composer.frame.height
        model.conversationID = UUID()
        model.text = "Short draft"
        try await wait { composer.editor.string == "Short draft" && composer.frame.height < long }
        let single = composer.frame.height
        XCTAssertLessThanOrEqual(single, 25, "Switching to a short draft must shrink the composer to one line")
        XCTAssertGreaterThan(single, 0)
        for (text, grows) in [("x\n", true), ("", false), ("x\n", true), ("x", false)] {
            model.text = text
            try await wait {
                composer.superview?.layoutSubtreeIfNeeded()
                return composer.editor.string == text && (grows ? composer.frame.height > single + 0.5
                    : abs(composer.frame.height - single) < 0.5)
            }
        }
        for lines in [3, 12] {
            model.text = Array(repeating: "line", count: lines).joined(separator: "\n")
            try await wait { composer.frame.height > single * 2.5 }
            XCTAssertLessThanOrEqual(composer.frame.height, single * 6 + 0.5, "\(lines) lines must be capped at six")
        }
        model.text = String(repeating: "wrapped text 👋 ", count: 100)
        try await wait { composer.editor.string.hasPrefix("wrapped") && composer.frame.height > single * 5 }
        XCTAssertLessThanOrEqual(composer.frame.height, single * 6 + 0.5, "A wrapped paragraph must be capped at six lines")
    }

    /// Undo restores the draft through its binding. Switching chats clears the
    /// undo history so undo cannot bring back another chat's text, and a draft
    /// update arriving mid-composition keeps the input method's marked text.
    func testUndoSwitchingChatsAndInputMethodCompositionKeepTheDraftConsistent() async throws {
        let (model, composer) = try await mount(text: "Hello")
        let editor = composer.editor
        model.focused = true
        try await wait { editor.window?.firstResponder === editor }
        editor.undoManager?.removeAllActions()
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertText(" there", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        XCTAssertEqual(model.text, "Hello there")
        XCTAssertEqual(editor.undoManager?.canUndo, true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "Hello")
        XCTAssertEqual(model.text, "Hello", "Undo must update the draft binding")

        editor.insertText(" again", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        XCTAssertEqual(editor.undoManager?.canUndo, true)
        model.conversationID = UUID()
        try await wait { editor.undoManager?.canUndo == false }
        XCTAssertEqual(editor.string, "Hello again")

        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        model.text = "Replaced elsewhere"
        model.placeholder = "Message Another Chat"
        try await wait { editor.placeholder == "Message Another Chat" }
        XCTAssertTrue(editor.hasMarkedText(), "A draft update must not cancel the input method's composition")
        XCTAssertEqual(editor.string, "Hello againにほ")
        editor.insertText("日本", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "Hello again日本")
        XCTAssertEqual(model.text, editor.string, "Committing the composition must update the draft")
    }

    /// Pasting styled text inserts it as plain composer text: the composer's
    /// font, no pasted colour and no attachments.
    func testPastingRichTextInsertsPlainText() async throws {
        let (model, composer) = try await mount(text: "")
        let editor = composer.editor
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let pasted = "Pasted text\nkeeps line breaks"
        let rich = NSAttributedString(string: pasted, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.systemRed])
        board.declareTypes([.string, .rtf], owner: nil)
        XCTAssertTrue(board.setString(pasted, forType: .string))
        XCTAssertTrue(board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf))
        XCTAssertTrue(editor.readSelection(from: board), "Text paste must be accepted")
        XCTAssertEqual(editor.string, pasted)
        XCTAssertEqual(model.text, pasted)
        let storage = try XCTUnwrap(editor.textStorage)
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.attachment])
            XCTAssertEqual((attributes[.font] as? NSFont)?.pointSize ?? 14, 14)
            XCTAssertNotEqual(attributes[.foregroundColor] as? NSColor, .systemRed)
        }
    }

    /// Image data alone on the clipboard, as Preview copies a selection, is
    /// offered for Paste and handed over as an attachment.
    func testPastingImageDataHandsItToAttachments() async throws {
        let (_, composer) = try await mount(text: "")
        let editor = composer.editor
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.png], owner: nil)
        XCTAssertTrue(board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png))
        var received: NSPasteboard?
        editor.pasteAttachments = { received = $0; return true }
        XCTAssertTrue(editor.readablePasteboardTypes.contains(.png), "Paste must be enabled for image data")
        XCTAssertTrue(editor.readSelection(from: board), "Image paste must be accepted")
        XCTAssertIdentical(received, board)
        XCTAssertEqual(editor.string, "")
    }

    /// The overlay that turns the composer's padding into a focus target lets
    /// clicks on the text itself through to the editor.
    func testPaddingFocusTargetPassesTextClicksThrough() async throws {
        let (_, composer) = try await mount(text: "Some draft text")
        let root = try XCTUnwrap(composer.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(view(named: "ComposerPaddingFocusView", in: root))
        let rect = composer.convert(composer.bounds, to: nil)
        let textPoint = try XCTUnwrap(target.superview).convert(NSPoint(x: rect.minX + 20, y: rect.midY), from: nil)
        XCTAssertNil(target.hitTest(textPoint), "The padding overlay must not intercept clicks on the text")
        let padding = try XCTUnwrap(target.superview).convert(NSPoint(x: rect.minX - 8, y: rect.midY), from: nil)
        XCTAssertTrue(target.hitTest(padding) === target, "Clicks in the padding beside the text must focus the editor")
    }

    // MARK: - Helpers

    private func mount(text: String? = nil) async throws -> (ComposerModel, ComposerScrollView) {
        let model = ComposerModel()
        if let text { model.text = text }
        let root = host(ComposerFixture(model: model))
        addTeardownBlock { @MainActor in model.completion.detach() }
        var found: ComposerScrollView?
        try await wait {
            root.layoutSubtreeIfNeeded()
            found = self.view(ofType: ComposerScrollView.self, in: root)
            return found?.editor.string == model.text && (found?.frame.height ?? 0) > 0
        }
        return (model, try XCTUnwrap(found))
    }

    private func view<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.view(ofType: type, in: $0) }.first
    }

    private func view(named name: String, in root: NSView) -> NSView? {
        if String(describing: Swift.type(of: root)) == name { return root }
        return root.subviews.lazy.compactMap { self.view(named: name, in: $0) }.first
    }
}

@MainActor private final class ComposerModel: ObservableObject {
    @Published var text = (1...60).map { "Line \($0): This is a long draft that stays editable." }.joined(separator: "\n")
    @Published var focused = false
    @Published var conversationID = UUID()
    @Published var placeholder = "Message Test"
    let completion = ComposerNameCompletion()
}

/// The chat's arrangement: an attachment button beside a nested stack holding
/// the composer, its trailing controls and the padding focus target.
private struct ComposerFixture: View {
    @ObservedObject var model: ComposerModel
    var body: some View {
        VStack(alignment: .leading) {
            Spacer()
            HStack(alignment: .bottom, spacing: 8) {
                Button("+") {}.frame(width: 36, height: 36)
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        ScrollableChatComposer(text: $model.text, isFocused: $model.focused,
                            conversationID: model.conversationID, placeholder: model.placeholder,
                            agents: [AgentRecord(displayName: "Mara")], preferredIDs: [], separatesPreferredAgents: false,
                            completion: model.completion, submit: {})
                        .padding(.leading, 12).padding(.trailing, 72).padding(.vertical, 6)
                        .frame(minHeight: 36)
                        HStack(spacing: 4) {
                            Button {} label: { Text("mic").frame(width: 27, height: 36) }
                            Button {} label: { Text("send").frame(width: 27, height: 36) }
                        }.buttonStyle(.plain).padding(.trailing, 7)
                    }
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
                    .modifier(ComposerFocusSurface(cornerRadius: 18, controlsWidth: 65) { model.focused = true })
                }
            }
        }.padding(20).frame(width: 500, height: 300)
    }
}
