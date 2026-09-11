import AppKit
import SwiftUI
import NoodleCore

@MainActor final class ComposerFixtureModel: ObservableObject {
    @Published var text = (1...60).map { "Line \($0): This is a long draft that stays editable." }.joined(separator: "\n")
    @Published var focused = false
    @Published var conversationID = UUID()
    @Published var submissions = 0
    @Published var microphoneClicks = 0
    @Published var width: CGFloat = 500
    let completion = ComposerNameCompletion()
}

struct ScrollableComposerFixture: View {
    @ObservedObject var model: ComposerFixtureModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("Scrollable composer — native editing").font(.headline)
            Spacer()
            // Match the chat's attachment row and nested voice/composer stack;
            // a lone fixed-width editor doesn't exercise SwiftUI's width probes.
            HStack(alignment: .bottom, spacing: 8) {
                Button("+") {}.frame(width: 36, height: 36)
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        ScrollableChatComposer(text: $model.text, isFocused: $model.focused,
                            conversationID: model.conversationID, placeholder: "Message Test",
                            agents: [AgentRecord(displayName: "Mara")], preferredIDs: [], separatesPreferredAgents: false,
                            completion: model.completion, submit: { model.submissions += 1 })
                        .padding(.leading, 12).padding(.trailing, 72).padding(.vertical, 6)
                        .frame(minHeight: 36)
                        HStack(spacing: 4) {
                            Button { model.microphoneClicks += 1 } label: { Text("mic").frame(width: 27, height: 36).contentShape(Rectangle()) }
                            Button { model.submissions += 1 } label: { Text("send").frame(width: 27, height: 36).contentShape(Rectangle()) }
                        }.buttonStyle(.plain).padding(.trailing, 7)
                    }
                    .modifier(ComposerFixtureStyle())
                    .modifier(ComposerFocusSurface(cornerRadius: 18, controlsWidth: 65) { model.focused = true })
                }
            }
        }.padding(20).frame(width: model.width, height: 300)
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
    /// A repeatable edit/layout workload, not a measurement of display latency.
    /// Keep timings informational: loaded machines must not fail correctness tests.
    @MainActor static func benchmark(_ scroll: ComposerScrollView, model: ComposerFixtureModel) async throws {
        model.focused = true
        for lines in [1, 60, 600] {
            model.text = String(repeating: "This is a draft used to measure typing and layout.\n", count: lines)
            try await Task.sleep(for: .milliseconds(200))
            var samples: [Double] = []
            for index in 0..<35 {
                let start = ProcessInfo.processInfo.systemUptime
                scroll.editor.insertText("x", replacementRange: scroll.editor.selectedRange())
                // Nested SwiftUI stacks probe minimum and allocated widths.
                _ = scroll.fittingHeight(width: 1)
                _ = scroll.fittingHeight(width: scroll.contentSize.width)
                scroll.window?.contentView?.layoutSubtreeIfNeeded()
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                if index >= 5 { samples.append(milliseconds) }
                try await Task.sleep(for: .milliseconds(10))
            }
            samples.sort()
            print(String(format: "Edit + width-probe layout, %d lines: median %.2f ms, p95 %.2f ms", lines,
                samples[samples.count / 2], samples[Int(Double(samples.count - 1) * 0.95)]))
        }
    }

    @MainActor static func main() {
        setbuf(stdout, nil)
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
                if CommandLine.arguments.contains("--benchmark") {
                    try await benchmark(scroll, model: model)
                    model.completion.detach()
                    window.orderOut(nil)
                    exit(0)
                }
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
                @MainActor func requireVisibleCaret(_ context: String) {
                    let screenRect = scroll.editor.firstRect(forCharacterRange: scroll.editor.selectedRange(), actualRange: nil)
                    let caret = scroll.editor.convert(window.convertFromScreen(screenRect), from: nil)
                    let visible = scroll.editor.visibleRect
                    precondition(caret.height > 0 && caret.minY >= visible.minY - 1 && caret.maxY <= visible.maxY + 1,
                        "\(context): caret \(caret) outside visible \(visible); document \(scroll.editor.frame)")
                }
                @MainActor func typeKey(_ characters: String, keyCode: UInt16 = 7) {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: keyCode)!
                    window.sendEvent(event)
                }
                scroll.editor.setSelectedRange(NSRange(location: (model.text as NSString).length, length: 0))
                scroll.editor.scrollRangeToVisible(scroll.editor.selectedRange())
                for character in "test" {
                    scroll.editor.insertText(String(character), replacementRange: scroll.editor.selectedRange())
                    try await Task.sleep(for: .milliseconds(100))
                    requireVisibleCaret("Typing at the end of an overflowing draft")
                }
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.editor.insertText("x", replacementRange: scroll.editor.selectedRange())
                try await Task.sleep(for: .milliseconds(150))
                requireVisibleCaret("Typing after manually scrolling away from the caret")
                let documentFrame = scroll.editor.frame
                let containerSize = scroll.editor.textContainer!.containerSize
                let viewport = scroll.contentView.bounds
                let selection = scroll.editor.selectedRange()
                for width in [CGFloat(1), 150, 700, scroll.contentSize.width] {
                    _ = scroll.fittingHeight(width: width)
                    precondition(scroll.editor.textContainer!.containerSize == containerSize && scroll.editor.frame == documentFrame,
                        "Speculative height measurement must not reflow the live editor")
                    precondition(scroll.contentView.bounds == viewport && scroll.editor.selectedRange() == selection,
                        "Speculative height measurement must preserve scroll and selection")
                }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
                scroll.reflectScrolledClipView(scroll.contentView)
                model.microphoneClicks += 0 // Trigger an unrelated SwiftUI update.
                try await Task.sleep(for: .milliseconds(150))
                precondition(abs(scroll.contentView.bounds.minY - 150) < 1,
                    "An unrelated update must preserve manual scrolling")
                typeKey("x")
                try await Task.sleep(for: .milliseconds(150))
                requireVisibleCaret("A native keystroke after manual scrolling")
                scroll.editor.undoManager?.removeAllActions()
                let before = model.text
                scroll.editor.breakUndoCoalescing()
                scroll.editor.setSelectedRange(NSRange(location: 0, length: 0))
                let shift = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                precondition(ComposerNameCompletion.insertLineBreak(for: shift, in: scroll.editor))
                precondition(model.text == "\n" + before)
                scroll.editor.breakUndoCoalescing()
                try await Task.sleep(for: .milliseconds(100))
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
                model.focused = true
                try await Task.sleep(for: .milliseconds(100))
                for count in 1...8 {
                    scroll.editor.insertText("\n", replacementRange: scroll.editor.selectedRange())
                    try await Task.sleep(for: .milliseconds(100))
                    let emptyLastLineHeight = scroll.frame.height
                    scroll.editor.insertText("x", replacementRange: scroll.editor.selectedRange())
                    try await Task.sleep(for: .milliseconds(100))
                    precondition(abs(scroll.frame.height - emptyLastLineHeight) < 0.5,
                        "Typing on empty line \(count + 1) must not shrink the composer")
                    precondition(scroll.frame.height <= singleLineHeight * 6 + 0.5)
                    requireVisibleCaret("Typing on line \(count + 1)")
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
                model.text = ""
                model.focused = true
                try await Task.sleep(for: .milliseconds(150))
                for word in 1...100 {
                    scroll.editor.insertText("wrapped text 👋 ", replacementRange: scroll.editor.selectedRange())
                    try await Task.sleep(for: .milliseconds(5))
                    if word.isMultiple(of: 10) {
                        try await Task.sleep(for: .milliseconds(50))
                        requireVisibleCaret("Growing a wrapped paragraph, word \(word)")
                    }
                }
                precondition(scroll.frame.height <= singleLineHeight * 6 + 0.5)
                precondition(scroll.contentView.bounds.minY > 0, "Wrapped typing must scroll past the height cap")
                for width in [CGFloat(420), 700, 500] {
                    model.width = width
                    window.setContentSize(NSSize(width: width, height: 300))
                    try await Task.sleep(for: .milliseconds(150))
                    typeKey("x")
                    try await Task.sleep(for: .milliseconds(100))
                    requireVisibleCaret("Typing after resizing to \(width)")
                }
                scroll.editor.setSelectedRange(NSRange(location: (model.text as NSString).length / 2, length: 0))
                typeKey("x")
                try await Task.sleep(for: .milliseconds(100))
                requireVisibleCaret("Editing in the middle of an overflowing paragraph")
                typeKey("\u{7f}", keyCode: 51)
                try await Task.sleep(for: .milliseconds(100))
                requireVisibleCaret("Deleting in the middle of an overflowing paragraph")
                scroll.editor.setSelectedRange(NSRange(location: (model.text as NSString).length, length: 0))
                scroll.editor.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0),
                    replacementRange: scroll.editor.selectedRange())
                try await Task.sleep(for: .milliseconds(100))
                precondition(scroll.editor.hasMarkedText(), "Layout must preserve IME composition")
                scroll.editor.insertText("日本語", replacementRange: scroll.editor.markedRange())
                try await Task.sleep(for: .milliseconds(100))
                requireVisibleCaret("Committing IME text at the end of an overflowing draft")
                precondition(model.text == scroll.editor.string && !scroll.editor.hasMarkedText())
                print("Overflow regression: wrapped typing, manual scrolling, measurement probes, resize, middle edits and IME passed")
                model.completion.detach()
                window.orderOut(nil)
                print("Scrollable composer: wheel scrolling, automatic scrollbar, six-line limit, focus, plain text, Return, Shift+Return, undo and draft switching passed")
                exit(0)
            } catch { print(error); exit(1) }
        }
        app.run()
    }
}
