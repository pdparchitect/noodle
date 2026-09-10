import AppKit
import QuickLookUI

// Feasibility probe only: no runtime, shell, network or user-library access.
@main enum PreviewEntry { static func main() {} }

@objc(ComputerPreviewProofController)
final class ComputerPreviewProofController: NSViewController, QLPreviewingController {
    private var editor: NSTextView?
    private var heading: NSTextField?
    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
        let heading = NSTextField(labelWithString: "Computer preview interaction proof")
        heading.frame = NSRect(x: 24, y: 370, width: 640, height: 24)
        root.addSubview(heading)
        self.heading = heading
        let explanation = NSTextField(labelWithString: "Click below and type: echo hello world. This does not run a command.")
        explanation.frame = NSRect(x: 24, y: 335, width: 650, height: 24)
        root.addSubview(explanation)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: 652, height: 290))
        scroll.autoresizingMask = [.width, .height]
        let editor = NSTextView(frame: scroll.bounds)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        editor.backgroundColor = .black
        editor.textColor = .white
        editor.string = "Preview input: "
        editor.setAccessibilityLabel("Computer preview input")
        self.editor = editor
        scroll.documentView = editor
        root.addSubview(scroll)
        view = root
        preferredContentSize = root.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let accepted = view.window?.makeFirstResponder(editor) ?? false
        heading?.stringValue = "Computer preview — keyboard focus accepted: \(accepted)"
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        _ = view
        handler(nil)
    }
}
