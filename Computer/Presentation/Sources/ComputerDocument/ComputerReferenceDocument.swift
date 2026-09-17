import AppKit
import ComputerBridge
import ImageIO

public enum ComputerReferenceDocument {
    public static var typeIdentifier: String { ComputerBuildIdentity.current.contentType }
    public static let maximumBytes = 900_000

    public static func decode(_ data: Data) throws -> ComputerReference {
        guard data.count <= maximumBytes else { throw ComputerBridgeError("This computer reference is too large.") }
        let card = try JSONDecoder().decode(ComputerReference.self, from: data)
        guard card.version == 1, card.computer.name.count <= 100,
              card.terminalPreview.utf8.count <= 16_000,
              card.view == nil || ["terminal", "web"].contains(card.view!),
              card.view == "web" || card.terminalID != nil else {
            throw ComputerBridgeError("This computer reference is unsupported or incomplete.")
        }
        return card
    }

    public static func read(_ url: URL, build: ComputerBuildIdentity = .current) throws -> ComputerReference {
        guard url.isFileURL else { throw ComputerBridgeError("Open a computer reference file.") }
        guard url.pathExtension.lowercased() == build.fileExtension else {
            throw ComputerBridgeError("Open a .\(build.fileExtension) reference in \(build.appName).")
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw ComputerBridgeError("This computer reference is not a supported file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: maximumBytes + 1) ?? Data())
    }

    /// Decode only a bounded thumbnail, even if an attachment contains a large image.
    public static func snapshot(_ card: ComputerReference) -> NSImage? {
        guard let data = card.previewImage,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// No live connection: a saved preview remains useful when either app is closed.
@MainActor public final class ComputerDocumentView: NSView {
    private let card: ComputerReference
    private let snapshot: NSImage?
    public init(card: ComputerReference, size: NSSize = NSSize(width: 800, height: 520)) {
        self.card = card
        snapshot = ComputerReferenceDocument.snapshot(card)
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(true)
        setAccessibilityLabel("Saved preview of \(card.computer.name). Open in Noodle Computer to interact.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var isFlipped: Bool { true }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Quick Look resizes the exported view during its opening animation.
        // NSView does not invalidate drawing when its frame changes.
        needsDisplay = true
    }
    public override func draw(_ dirtyRect: NSRect) {
        let content = bounds
        NSColor.black.setFill(); content.fill()
        if let snapshot, snapshot.size.width > 0, snapshot.size.height > 0 {
            let scale = min(content.width / snapshot.size.width, content.height / snapshot.size.height)
            let size = NSSize(width: snapshot.size.width * scale, height: snapshot.size.height * scale)
            snapshot.draw(in: NSRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2,
                width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
        } else {
            NSGraphicsContext.saveGraphicsState(); content.clip()
            let text = card.view == "web" ? "Desktop snapshot unavailable" : (card.terminalPreview.isEmpty ? "$" : card.terminalPreview)
            NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white]).draw(in: content.insetBy(dx: 14, dy: 14))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
