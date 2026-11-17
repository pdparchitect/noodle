import AppKit
import NoodleCore

extension AttachmentTransfer {
    /// Attaches what a paste from `pasteboard` holds with `store`; false leaves the paste to the text field.
    @MainActor public static func paste(from pasteboard: NSPasteboard, textAsAttachment: Bool = false,
                                        store: (AttachmentTransferPayload) -> Bool) -> Bool {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return paste(pastedPayloads(fileURLs: files, png: pasteboard.data(forType: .png), tiff: pasteboard.data(forType: .tiff),
                                    text: pasteboard.string(forType: .string), textAsAttachment: textAsAttachment), store: store)
    }
}
