import AppKit
import SwiftUI
import NoodleCore

/// A real scroll view keeps long drafts reachable with a trackpad even when the
/// editor isn't focused. SwiftUI retains ownership of the draft and outer styling.
struct ScrollableChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let conversationID: UUID
    let placeholder: String
    let agents: [AgentRecord]
    let preferredIDs: Set<UUID>
    let completion: ComposerNameCompletion
    let submit: () -> Void
    var focusSidebar: (() -> Void)? = nil
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showDescriptions = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ComposerScrollView {
        let view = ComposerScrollView()
        view.editor.delegate = context.coordinator
        context.coordinator.view = view
        view.focusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }
        return view
    }

    func updateNSView(_ view: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        let requestFocus = isFocused && !context.coordinator.lastRequestedFocus
        context.coordinator.lastRequestedFocus = isFocused
        let focusRevision = context.coordinator.focusRevision
        view.editor.placeholder = placeholder
        view.editor.setAccessibilityLabel(placeholder)
        if context.coordinator.conversationID != conversationID {
            completion.detach()
            context.coordinator.conversationID = conversationID
            view.editor.undoManager?.removeAllActions()
            view.editor.string = text
            view.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.editor.scrollRangeToVisible(view.editor.selectedRange())
        } else if view.editor.string != text, !view.editor.hasMarkedText() {
            view.editor.string = text
            view.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.editor.scrollRangeToVisible(view.editor.selectedRange())
        }
        view.editor.needsDisplay = true
        view.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            if requestFocus, coordinator.focusRevision == focusRevision,
               coordinator.parent.isFocused, view.window?.firstResponder !== view.editor {
                view.window?.makeFirstResponder(view.editor)
            }
            coordinator.attachCompletion()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 300)
        return CGSize(width: width, height: nsView.fittingHeight(width: width))
    }

    static func dismantleNSView(_ view: ComposerScrollView, coordinator: Coordinator) {
        coordinator.parent.completion.detach()
        view.focusChanged = nil
        view.editor.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScrollableChatComposer
        var conversationID: UUID?
        var lastRequestedFocus = false
        var focusRevision = 0
        weak var view: ComposerScrollView?
        init(_ parent: ScrollableChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.editor.string
            view.editor.needsDisplay = true
            view.invalidateIntrinsicContentSize()
            view.editor.scrollRangeToVisible(view.editor.selectedRange())
        }

        func focusChanged(_ focused: Bool) {
            focusRevision += 1
            let revision = focusRevision
            // Do not mutate SwiftUI state during its own AppKit update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRevision == revision,
                      let view = self.view, (view.window?.firstResponder === view.editor) == focused else { return }
                if self.parent.isFocused != focused { self.parent.isFocused = focused }
                if focused { self.attachCompletion() } else { self.parent.completion.detach() }
            }
        }

        func attachCompletion() {
            guard let view, view.window?.firstResponder === view.editor else { return }
            parent.completion.attach(to: view.editor, anchor: view, agents: parent.agents,
                preferredIDs: parent.preferredIDs, showDescriptions: parent.showDescriptions)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option, .control, .command]) ?? []
            if commandSelector == #selector(NSResponder.insertBacktab(_:)),
               modifiers.intersection([.option, .control, .command]).isEmpty,
               let focusSidebar = parent.focusSidebar {
                parent.completion.detach()
                parent.isFocused = false
                focusSidebar()
                return true
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if modifiers.contains(.shift) || modifiers.contains(.option) { return false }
            parent.submit()
            return true
        }
    }
}

@MainActor final class ComposerScrollView: NSScrollView {
    let editor = ComposerTextView(frame: .zero)
    var focusChanged: ((Bool) -> Void)?
    private let composerFont = NSFont.systemFont(ofSize: 14)

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .automatic
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = composerFont
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        documentView = editor
        editor.focusChanged = { [weak self] in self?.focusChanged?($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let container = editor.textContainer, let layout = editor.layoutManager else { return 17 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = ceil(layout.defaultLineHeight(for: composerFont))
        // The extra fragment overlaps the used rect for an empty editor. Adding
        // their heights counts that line twice and shifts the transcript as the
        // first character is entered. Measure their union's bottom instead.
        let used = ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY))
        return min(line * 6, max(line, used))
    }
}

@MainActor final class ComposerTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(at: .zero, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor
        ])
    }
}
