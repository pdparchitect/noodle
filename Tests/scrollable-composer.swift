import AppKit
import SwiftUI
import NoodleCore

@MainActor final class ComposerFixtureModel: ObservableObject {
    @Published var text = (1...60).map { "Line \($0): This is a long draft that stays editable." }.joined(separator: "\n")
    @Published var focused = false
    @Published var conversationID = UUID()
    @Published var submissions = 0
    @Published var microphoneClicks = 0
    let completion = ComposerNameCompletion()
}

struct ScrollableComposerFixture: View {
    @ObservedObject var model: ComposerFixtureModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("Scrollable composer — native editing").font(.headline)
            Spacer()
            ZStack(alignment: .bottomTrailing) {
                ScrollableChatComposer(text: $model.text, isFocused: $model.focused,
                conversationID: model.conversationID, placeholder: "Message Test",
                agents: [AgentRecord(displayName: "Mara")], preferredIDs: [], completion: model.completion,
                submit: { model.submissions += 1 })
                .padding(.leading, 12).padding(.trailing, 72).padding(.vertical, 6)
                .frame(minHeight: 36)
                HStack(spacing: 4) {
                    Button { model.microphoneClicks += 1 } label: { Text("mic").frame(width: 27, height: 36).contentShape(Rectangle()) }
                    Button { model.submissions += 1 } label: { Text("send").frame(width: 27, height: 36).contentShape(Rectangle()) }
                }.buttonStyle(.plain).padding(.trailing, 7)
            }
            .modifier(ComposerFixtureStyle())
            .modifier(ComposerFocusSurface(cornerRadius: 18, controlsWidth: 65) { model.focused = true })
        }.padding(20).frame(width: 500, height: 300)
    }
}

private struct ComposerFixtureStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

@main enum ScrollableComposerChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = ComposerFixtureModel()
        let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Scrollable Composer Tests"
        window.contentView = NSHostingView(rootView: ScrollableComposerFixture(model: model))
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                @MainActor func find(_ view: NSView) -> ComposerScrollView? {
                    if let scroll = view as? ComposerScrollView { return scroll }
                    for child in view.subviews { if let found = find(child) { return found } }
                    return nil
                }
                guard let scroll = find(window.contentView!) else { fatalError("Missing native scroll view") }
                precondition(scroll.hasVerticalScroller && scroll.autohidesScrollers && scroll.scrollerStyle == .overlay)
                precondition(scroll.frame.height <= 110 && scroll.frame.height >= 90)
                precondition(scroll.editor.bounds.height > scroll.contentSize.height * 2, "Long text must have scrollable extent")
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -150, wheel2: 0, wheel3: 0)!
                scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
                try await Task.sleep(for: .milliseconds(300))
                precondition(scroll.contentView.bounds.minY > 0, "Trackpad-style pixel scrolling must move the draft")
                print("Trackpad-style scroll moved draft to y=\(scroll.contentView.bounds.minY)")
                model.focused = true
                try await Task.sleep(for: .milliseconds(200))
                precondition(window.firstResponder === scroll.editor)
                precondition(!scroll.editor.isRichText && !scroll.editor.importsGraphics)
                let before = model.text
                scroll.editor.setSelectedRange(NSRange(location: 0, length: 0))
                let shift = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                precondition(ComposerNameCompletion.insertLineBreak(for: shift, in: scroll.editor))
                precondition(model.text == "\n" + before)
                scroll.editor.undoManager?.undo()
                precondition(model.text == before, "Native undo must preserve the draft binding")
                let handled = scroll.editor.delegate?.textView?(scroll.editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                precondition(handled == true && model.submissions == 1)
                model.conversationID = UUID()
                model.text = "Short draft"
                try await Task.sleep(for: .milliseconds(300))
                precondition(scroll.editor.string == "Short draft")
                precondition(scroll.frame.height <= 25, "Composer must shrink after switching to a short draft")
                let singleLineHeight = scroll.frame.height
                precondition(scroll.editor.undoManager?.canUndo != true, "Undo must not restore another chat's draft")
                model.text = ""
                try await Task.sleep(for: .milliseconds(150))
                precondition(scroll.editor.string.isEmpty && scroll.editor.placeholder == "Message Test")
                precondition(abs(scroll.frame.height - singleLineHeight) < 0.5, "Empty and one-line drafts must have identical height")
                model.text = "x"
                try await Task.sleep(for: .milliseconds(150))
                precondition(abs(scroll.frame.height - singleLineHeight) < 0.5, "Typing the first character must not shift the layout")
                model.text = "x\n"
                try await Task.sleep(for: .milliseconds(150))
                precondition(scroll.frame.height > singleLineHeight, "An actual trailing newline must still grow the editor")
                model.text = ""
                try await Task.sleep(for: .milliseconds(150))
                precondition(abs(scroll.frame.height - singleLineHeight) < 0.5, "Clearing text must restore the same single-line height")
                @MainActor func click(_ point: NSPoint) async throws {
                    window.makeFirstResponder(nil)
                    model.focused = false
                    try await Task.sleep(for: .milliseconds(100))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        window.sendEvent(event)
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                let rect = scroll.convert(scroll.bounds, to: nil)
                @MainActor func paddingTarget(_ root: NSView) -> NSView? {
                    if String(describing: type(of: root)) == "ComposerPaddingFocusView" { return root }
                    for child in root.subviews { if let target = paddingTarget(child) { return target } }
                    return nil
                }
                let target = paddingTarget(window.contentView!)!
                let textPoint = target.superview!.convert(NSPoint(x: rect.minX + 20, y: rect.midY), from: nil)
                precondition(target.hitTest(textPoint) == nil, "Padding overlay must pass text clicks through")
                for point in [NSPoint(x: rect.midX, y: rect.minY - 4),
                              NSPoint(x: rect.midX, y: rect.maxY + 4),
                              NSPoint(x: rect.minX - 8, y: rect.midY),
                              NSPoint(x: rect.minX - 5, y: rect.minY - 2)] {
                    try await click(point)
                    precondition(window.firstResponder === scroll.editor, "Input padding click must focus the editor: \(point)")
                }
                let sends = model.submissions
                try await click(NSPoint(x: rect.maxX + 72 - 7 - 13.5, y: rect.midY))
                precondition(model.submissions == sends + 1 && !model.focused, "Send button must not trigger background focus")
                try await click(NSPoint(x: rect.maxX + 72 - 7 - 13.5 - 31, y: rect.midY))
                precondition(model.microphoneClicks == 1 && !model.focused, "Microphone must not trigger background focus")
                print("Composer padding: top, bottom, left and rounded corner focus; send and microphone remain independent")
                for count in 1...8 {
                    scroll.editor.insertText("\n", replacementRange: scroll.editor.selectedRange())
                    try await Task.sleep(for: .milliseconds(100))
                    let emptyLastLineHeight = scroll.frame.height
                    scroll.editor.insertText("x", replacementRange: scroll.editor.selectedRange())
                    try await Task.sleep(for: .milliseconds(100))
                    precondition(abs(scroll.frame.height - emptyLastLineHeight) < 0.5,
                        "Typing on empty line \(count + 1) must not shrink the composer")
                    precondition(scroll.frame.height <= singleLineHeight * 6 + 0.5)
                }
                model.text = ""
                try await Task.sleep(for: .milliseconds(150))
                // A private pasteboard leaves the user's clipboard untouched.
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                let pasted = "Pasted text\nkeeps line breaks"
                let rich = NSAttributedString(string: pasted, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.systemRed
                ])
                pasteboard.declareTypes([.string, .rtf], owner: nil)
                pasteboard.setString(pasted, forType: .string)
                pasteboard.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
                precondition(scroll.editor.readSelection(from: pasteboard), "Text paste must be accepted")
                precondition(scroll.editor.string == pasted)
                scroll.editor.textStorage?.enumerateAttributes(in: NSRange(location: 0, length: (pasted as NSString).length)) { attributes, _, _ in
                    precondition(attributes[.attachment] == nil)
                    if let font = attributes[.font] as? NSFont { precondition(font.pointSize == 14) }
                    precondition(attributes[.foregroundColor] as? NSColor != .systemRed)
                }
                model.completion.detach()
                window.orderOut(nil)
                print("Scrollable composer: wheel scrolling, automatic scrollbar, six-line limit, focus, plain text, Return, Shift+Return, undo and draft switching passed")
                exit(0)
            } catch { print(error); exit(1) }
        }
        app.run()
    }
}
