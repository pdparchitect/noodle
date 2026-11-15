import AppKit
import NoodleCore

extension AttachmentTransfer {
    /// What a paste from `pasteboard` attaches, read as every app's composer reads it; nil pastes as text.
    @MainActor public static func pastedPayloads(from pasteboard: NSPasteboard, textAsAttachment: Bool = false) -> [AttachmentTransferPayload]? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return pastedPayloads(fileURLs: files, png: pasteboard.data(forType: .png), tiff: pasteboard.data(forType: .tiff),
                              text: pasteboard.string(forType: .string), textAsAttachment: textAsAttachment)
    }
}
