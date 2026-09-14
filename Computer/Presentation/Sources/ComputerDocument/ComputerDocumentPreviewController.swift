import AppKit
import QuickLookUI

/// Quick Look exports the root view through ViewBridge before preparing the
/// file. Preserve that root for the entire extension request.
@MainActor open class ComputerDocumentPreviewController: NSViewController, @preconcurrency QLPreviewingController {
    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        preferredContentSize = view.frame.size
    }

    public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let card = try ComputerReferenceDocument.read(url)
            let root = view
            let content = ComputerDocumentView(card: card, size: root.bounds.size)
            content.autoresizingMask = [.width, .height]
            root.subviews.forEach { $0.removeFromSuperview() }
            root.addSubview(content)
            handler(nil)
        } catch { handler(error) }
    }
}
