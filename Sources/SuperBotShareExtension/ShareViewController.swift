import AppKit
import SwiftUI
import SuperBotCore
import SuperBotSharing

// SwiftPM requires a main symbol; the extension linker entry is NSExtensionMain.
@main
enum ShareExtensionEntry {
    static func main() {}
}

@objc(SuperBotShareViewController)
final class ShareViewController: NSViewController {
    private var composer: ShareComposerModel?

    override func loadView() {
        do {
            let model = ShareComposerModel(inbox: try SharedInbox.configured())
            composer = model
            view = NSHostingView(rootView: ShareComposer(model: model, send: { [weak self] in self?.send() },
                                                        cancel: { [weak self] in self?.cancel() }))
        } catch {
            let label = NSTextField(wrappingLabelWithString: error.localizedDescription)
            label.frame = NSRect(x: 20, y: 20, width: 380, height: 80)
            view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
            view.addSubview(label)
        }
        preferredContentSize = NSSize(width: 460, height: 380)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var inputs: [ShareInput] = []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { inputs.append(.text(text)) }
            inputs += (item.attachments ?? []).map(ShareInput.provider)
        }
        composer?.load(inputs)
    }

    private func send() {
        do {
            try composer?.send()
            // Only an opaque wake-up signal leaves the shared container; no text or file paths in URLs.
            NSWorkspace.shared.open(URL(string: "superbot://shared")!)
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch { composer?.error = error.localizedDescription }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        composer?.cancel()
    }

    private func cancel() {
        composer?.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
