import AppKit
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class ComposerNameCompletionTests: XCTestCase {
    private func returnKey(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 36) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                         keyCode: keyCode)!
    }

    /// Return sends; Shift-Return and the keypad's Shift-Enter break the line at the selection. Any other
    /// modifier, or text still being composed by an input method, is left to the editor.
    func testShiftReturnBreaksTheLineAndEverythingElseIsLeftAlone() {
        let editor = NSTextView(frame: .zero)
        editor.isEditable = true
        editor.string = "Hi 👋 world"
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        XCTAssertFalse(ComposerNameCompletion.insertLineBreak(for: returnKey([]), in: editor))
        XCTAssertEqual(editor.string, "Hi 👋 world")
        XCTAssertTrue(ComposerNameCompletion.insertLineBreak(for: returnKey(.shift), in: editor))
        XCTAssertEqual(editor.string, "Hi 👋\nworld")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertTrue(ComposerNameCompletion.insertLineBreak(for: returnKey(.shift, keyCode: 76), in: editor))
        XCTAssertEqual(editor.string, "Hi 👋\n\nworld")
        for flags: NSEvent.ModifierFlags in [.command, .option, [.shift, .command], [.shift, .control]] {
            XCTAssertFalse(ComposerNameCompletion.insertLineBreak(for: returnKey(flags), in: editor), "\(flags)")
        }
        editor.setMarkedText("composing", selectedRange: NSRange(location: 0, length: 0), replacementRange: editor.selectedRange())
        XCTAssertFalse(ComposerNameCompletion.insertLineBreak(for: returnKey(.shift), in: editor))
    }

    /// The @ menu shows a bot's description on one line, cut to 72 characters.
    func testNameMenuTitlesCollapseAndShortenDescriptions() {
        let mara = AgentRecord(displayName: "Mara", publicDescription: "  Reviews\n ideas.  ")
        XCTAssertEqual(ComposerNameCompletion.menuTitle(for: mara, showDescriptions: false), "Mara")
        XCTAssertEqual(ComposerNameCompletion.menuTitle(for: mara, showDescriptions: true), "Mara  Reviews ideas.")
        XCTAssertEqual(ComposerNameCompletion.menuTitle(for: AgentRecord(displayName: "Ruby"), showDescriptions: true), "Ruby")
        let long = AgentRecord(displayName: "Long", publicDescription: String(repeating: "x", count: 200))
        XCTAssertEqual(ComposerNameCompletion.menuTitle(for: long, showDescriptions: true),
                       "Long  " + String(repeating: "x", count: 72) + "…")
    }

    /// Menu avatars are round, full colour and follow the bot's photo, colour and symbol. Unreadable
    /// photo data falls back to the generated avatar.
    func testNameMenuAvatarsAreRoundAndFollowTheBotsAppearance() throws {
        let photo = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }.tiffRepresentation
        let avatar = try XCTUnwrap(ComposerNameCompletion.menuAvatar(for: AgentRecord(displayName: "Mara", avatarImageData: photo)))
        let pixels = try bitmap(avatar)
        XCTAssertLessThan(try XCTUnwrap(pixels.colorAt(x: 0, y: 0)).alphaComponent, 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)).alphaComponent, 0.9)
        XCTAssertFalse(avatar.isTemplate)
        XCTAssertEqual(avatar.size, NSSize(width: 16, height: 16))

        let generated = AgentRecord(displayName: "Generated", accentSeed: 0)
        let generatedImage = try XCTUnwrap(ComposerNameCompletion.menuAvatar(for: generated))
        let generatedPixels = try bitmap(generatedImage)
        XCTAssertEqual(generatedPixels.pixelsWide, 32)
        XCTAssertEqual(generatedPixels.pixelsHigh, 32)
        XCTAssertLessThan(try XCTUnwrap(generatedPixels.colorAt(x: 0, y: 0)).alphaComponent, 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(generatedPixels.colorAt(x: 8, y: 16)).alphaComponent, 0.9)
        var customized = generated
        customized.avatarColorIndex = 2
        XCTAssertGreaterThan(try difference(ComposerNameCompletion.menuAvatar(for: customized), generatedImage), 0.01)
        customized = generated
        customized.avatarSymbolName = "heart.fill"
        XCTAssertGreaterThan(try difference(ComposerNameCompletion.menuAvatar(for: customized), generatedImage), 0.005)
        customized = generated
        customized.avatarImageData = Data([0, 1, 2])
        XCTAssertLessThan(try difference(ComposerNameCompletion.menuAvatar(for: customized), generatedImage), 0.002)
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    }

    /// Mean per-channel difference between two images of the same size, from 0 to 1.
    private func difference(_ lhs: NSImage?, _ rhs: NSImage) throws -> CGFloat {
        let a = try bitmap(try XCTUnwrap(lhs)), b = try bitmap(rhs)
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var total: CGFloat = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let c = try XCTUnwrap(a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let d = try XCTUnwrap(b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                total += abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent)
                    + abs(c.blueComponent - d.blueComponent) + abs(c.alphaComponent - d.alphaComponent)
            }
        }
        return total / CGFloat(a.pixelsWide * a.pixelsHigh * 4)
    }
}
