import Foundation
import HubLink
import NoodleWallpaperCore
@testable import NoodleMobile
import Testing
import UIKit
import UniformTypeIdentifiers

/// Pasting into the message field as on the Mac: files attach as files, and text past the Mac's
/// limits attaches as a text file named as the Mac names one.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ComposerPasteTests {
    private func pasteboard() -> UIPasteboard { UIPasteboard.withUniqueName() }

    @Test func longTextAttachesAsPastedTextAtTheMacsLimits() throws {
        let board = pasteboard()
        defer { UIPasteboard.remove(withName: board.name) }
        let field = PastingTextView()
        var pasted: ComposerPaste?
        field.pasted = { pasted = $0 }

        board.string = Array(repeating: "line", count: 12).joined(separator: "\n")
        #expect(!field.attachPaste(from: board), "short text goes into the field")
        #expect(pasted == nil)

        let long = Array(repeating: "line", count: 13).joined(separator: "\n")
        board.string = long
        #expect(field.attachPaste(from: board))
        guard case .text(let text)? = pasted else { Issue.record("long text did not attach: \(String(describing: pasted))"); return }
        #expect(text == long)
        #expect(field.text.isEmpty)

        board.string = String(repeating: "a", count: 1_201)
        guard case .text? = ComposerPaste.read(from: board) else { Issue.record("1,201 characters did not attach"); return }

        let file = try ComposerPaste.textFile(long)
        #expect(file.filename == "Pasted Text.txt")
        #expect(file.mediaType == "text/plain")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == long)
    }

    /// Copy File on a Metal shader in the conversation pastes into its Background settings as the shader.
    @Test func aCopiedShaderPastesAsTheBackground() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Aurora.metal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
            #include <metal_stdlib>
            #include <SwiftUI/SwiftUI_Metal.h>
            using namespace metal;

            [[ stitchable ]] half4 aurora(float2 position, half4 color, float2 size, float time) {
                float2 uv = position / size;
                return half4(half3(uv.y, 0.5h + 0.5h * half(sin(uv.x * 6.0 + time)), 1.0h - uv.y), 1.0h) * color.a;
            }
            """.write(to: url, atomically: true, encoding: .utf8)
        #expect(AttachmentClipboard.isText(LinkAttachment(id: UUID(), filename: "Aurora.metal", mediaType: "application/octet-stream", byteCount: 1)))
        let board = pasteboard()
        defer { UIPasteboard.remove(withName: board.name) }

        AttachmentClipboard.copyFile(url, named: "Aurora.metal", to: board)

        let provider = try #require(board.itemProviders.first)
        let pasted: PastedBackground = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PastedBackground.self) { continuation.resume(with: $0) }
        }
        #expect(try await pasted.prepare().kind == .shader)
    }

    /// Copy File on a text file in the conversation pastes back as that file, named as it was, not as its text.
    @Test func aCopiedFilePastesAsTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hubs = folder.appendingPathComponent("Hubs", isDirectory: true)
        let url = hubs.appendingPathComponent("Hub/Files/\(UUID().uuidString)/notes.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("A few words".utf8).write(to: url)
        let board = pasteboard()
        defer { UIPasteboard.remove(withName: board.name) }

        AttachmentClipboard.copyFile(url, named: "notes.txt", to: board)

        guard case .files(let providers)? = ComposerPaste.read(from: board) else { Issue.record("the file did not paste as a file"); return }
        let files = await ComposerPaste.load(providers, hubs: hubs, ownFolders: [folder])
        #expect(files.map(\.filename) == ["notes.txt"])
        #expect(files.first?.mediaType == "text/plain")
        let file = try #require(files.first)
        #expect(file.url != url, "the pasted file is a copy that stays until sent")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "A few words")
    }

    /// Any app can put a file's location on the pasteboard, so Noodle's own files, such as a Hub's
    /// key, are not read from one; only a conversation's files, which Copy File copies, are.
    @Test func aPastedLocationInsideNoodleIsReadOnlyFromAConversationsFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hubs = folder.appendingPathComponent("Hubs", isDirectory: true)
        let key = hubs.appendingPathComponent("Hub/identity.key")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: key)
        func pasted(ownFolders: [URL]) async -> [String] {
            await ComposerPaste.load([NSItemProvider(object: key as NSURL)], hubs: hubs, ownFolders: ownFolders)
                .compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        }

        let inside = await pasted(ownFolders: [folder])
        #expect(!inside.contains("secret"))
        let outside = await pasted(ownFolders: [])
        #expect(outside.contains("secret"), "the same file outside Noodle is read")

        let files = hubs.appendingPathComponent("Hub/Files", isDirectory: true)
        #expect(ComposerPaste.mayRead(files.appendingPathComponent("\(UUID().uuidString)/notes.txt"), hubs: hubs, ownFolders: [folder]))
        #expect(!ComposerPaste.mayRead(files.appendingPathComponent("x/../../identity.key"), hubs: hubs, ownFolders: [folder]))
        #expect(!ComposerPaste.mayRead(files.appendingPathComponent("x/y/notes.txt"), hubs: hubs, ownFolders: [folder]))
        #expect(!ComposerPaste.mayRead(folder.appendingPathComponent("Library/Preferences/settings.plist"), hubs: hubs, ownFolders: [folder]))
        #expect(ComposerPaste.mayRead(URL(fileURLWithPath: "/Elsewhere/notes.txt"), hubs: hubs, ownFolders: [folder]))
    }

    /// Another app's copied file comes with its name; copied words come without one, or with a name
    /// that is not their type, as a page's title would be.
    @Test func onlyACopiedFileCountsAsAFile() {
        #expect(ComposerPaste.isFile(types: [UTType.fileURL.identifier], suggestedName: nil))
        #expect(ComposerPaste.isFile(types: [UTType.plainText.identifier], suggestedName: "notes.txt"))
        #expect(ComposerPaste.isFile(types: [UTType.pdf.identifier], suggestedName: "Report.pdf"))
        #expect(!ComposerPaste.isFile(types: [UTType.utf8PlainText.identifier], suggestedName: nil))
        #expect(!ComposerPaste.isFile(types: [UTType.utf8PlainText.identifier, UTType.html.identifier], suggestedName: "Node.js"))
        #expect(!ComposerPaste.isFile(types: [UTType.plainText.identifier], suggestedName: "Notes"))
        #expect(!ComposerPaste.isFile(types: [UTType.url.identifier], suggestedName: nil))
    }

    @Test func onlyTextFilesOfferCopyFile() {
        func attachment(_ filename: String, _ mediaType: String) -> LinkAttachment {
            LinkAttachment(id: UUID(), filename: filename, mediaType: mediaType, byteCount: 10)
        }
        #expect(AttachmentClipboard.isText(attachment("notes.txt", "text/plain")))
        #expect(AttachmentClipboard.isText(attachment("data.json", "application/json")))
        #expect(AttachmentClipboard.isText(attachment("script.py", "application/octet-stream")))
        #expect(!AttachmentClipboard.isText(attachment("Photo.jpg", "image/jpeg")))
        #expect(!AttachmentClipboard.isText(attachment("Report.pdf", "application/pdf")))
    }
}
