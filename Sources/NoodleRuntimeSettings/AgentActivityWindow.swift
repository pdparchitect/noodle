import AppKit
import NoodleCore
import NoodleRuntime

/// One activity window per bot, for Noodle and Noodle Hub.
@MainActor
public final class AgentActivityWindows {
    public private(set) var controllers: [UUID: AgentActivityWindowController] = [:]

    public init() {}

    @discardableResult
    public func show(agent: AgentRecord, log: AgentActivityLog) -> AgentActivityWindowController {
        let controller: AgentActivityWindowController
        if let existing = controllers[agent.id] {
            controller = existing
        } else {
            controller = AgentActivityWindowController(log: log)
            controller.onClose = { [weak self] in self?.controllers[agent.id] = nil }
            controllers[agent.id] = controller
        }
        controller.updateTitle(agent.displayName)
        controller.refresh()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // Opening always lands on the latest output; follow needs the laid-out size.
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.output.follow()
        return controller
    }

    public func synchronize(agents: [AgentRecord]) {
        let names = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.displayName) })
        for (id, controller) in Array(controllers) {
            if let name = names[id] { controller.updateTitle(name) }
            else { controller.close() }
        }
    }
}

@MainActor
public final class AgentActivityWindowController: NSWindowController, NSWindowDelegate {
    let log: AgentActivityLog
    let output = AgentActivityTextView()
    private let empty = ActivityEmptyLabel(labelWithString: "No activity yet")
    private var timer: Timer?
    private var revision = -1
    var onClose: (() -> Void)?

    init(log: AgentActivityLog) {
        self.log = log
        let panel = AgentActivityPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .fullScreenDisallowsTiling]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        panel.minSize = NSSize(width: 440, height: 260)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.center()
        super.init(window: panel)
        panel.delegate = self

        output.textView.activityMenu = { [weak self] in self?.makeContextMenu() }
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        let content = NSView()
        for view in [output, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            output.topAnchor.constraint(equalTo: content.topAnchor),
            output.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            output.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            output.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: output.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: output.centerYAnchor)
        ])
        panel.contentView = AnnotationPreviewFrame(content: content, filename: "Activity", kindLabel: "",
            closeHint: "Close Activity (Esc or ⌘W)", closeLabel: "Close Activity")
        // Rendering is batched independently of token rate and runtime callbacks.
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.refresh()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { nil }

    func updateTitle(_ agentName: String) {
        let title = "\(agentName) - Activity"
        window?.title = title
        (window?.contentView as? AnnotationPreviewFrame)?.filename = title
    }

    func refresh() {
        if revision != log.revision {
            output.update(log.entries)
            revision = log.revision
            empty.isHidden = !log.entries.isEmpty
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, action: Selector, target: AnyObject, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let hasEntries = !log.entries.isEmpty
        add("Copy", action: #selector(NSText.copy(_:)), target: output.textView,
            enabled: output.textView.selectedRange().length > 0)
        add("Copy All", action: #selector(copyLog), target: self, enabled: hasEntries)
        add("Select All", action: #selector(NSText.selectAll(_:)), target: output.textView, enabled: hasEntries)
        menu.addItem(.separator())
        add("Follow Latest", action: #selector(followLog), target: self, enabled: hasEntries && !output.isFollowing)
        add("Clear", action: #selector(clearLog), target: self, enabled: hasEntries)
        return menu
    }

    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.text, forType: .string)
    }

    @objc private func clearLog() { log.clear(); refresh() }
    @objc private func followLog() { output.follow(); refresh() }

    public func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }

    deinit { timer?.invalidate() }
}

@MainActor
private final class AgentActivityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func zoom(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}
    override func toggleFullScreen(_ sender: Any?) {}
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Native selectable text keeps standard Find/Copy/Select All behavior. Updating
/// just the changed suffix preserves selections and avoids rebuilding on every token.
@MainActor
final class AgentActivityTextView: NSScrollView {
    let textView = ActivityLogTextView()
    let latestButton = NSGlassEffectView()
    private var rendered: [AgentActivityEntry] = []

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Agent Activity")
        documentView = textView

        let button = NSButton(image: NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))!, target: self, action: #selector(followLatest))
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = "Follow Latest"
        button.setAccessibilityLabel("Follow Latest")
        latestButton.contentView = button
        latestButton.cornerRadius = Self.latestButtonSize / 2
        latestButton.isHidden = true
        addSubview(latestButton)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Make the whole log area available to the context menu, even when empty.
        if textView.minSize.height != contentSize.height {
            textView.minSize = NSSize(width: 0, height: contentSize.height)
        }
        let size = Self.latestButtonSize
        latestButton.frame = NSRect(x: (bounds.width - size) / 2, y: isFlipped ? bounds.height - size - 16 : 16,
                                    width: size, height: size)
        updateLatestButton()
    }

    private static let latestButtonSize: CGFloat = 34

    @objc private func clipViewScrolled() { updateLatestButton() }
    @objc private func followLatest() { follow() }

    /// Floats over the log only while the newest output is out of view.
    private func updateLatestButton() {
        let hidden = isAtBottom || rendered.isEmpty
        guard hidden != latestButton.isHidden else { return }
        latestButton.isHidden = hidden
        if !hidden {
            latestButton.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; latestButton.animator().alphaValue = 1 }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { textView.activityMenu?() }

    var isAtBottom: Bool { textView.bounds.maxY - contentView.bounds.maxY <= 4 }
    var isFollowing: Bool { isAtBottom && textView.selectedRange().length == 0 }

    func follow() {
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.scrollToEndOfDocument(nil)
    }

    func update(_ entries: [AgentActivityEntry]) {
        guard entries != rendered, let storage = textView.textStorage else { return }
        let following = isFollowing
        let selection = textView.selectedRange()
        let origin = contentView.bounds.origin
        var removed = 0
        var removedHeight: CGFloat = 0
        if let first = entries.first, let index = rendered.firstIndex(where: { $0.id == first.id }), index > 0 {
            removed = rendered.prefix(index).reduce(0) { $0 + $1.text.utf16.count }
            if let manager = textView.layoutManager, let container = textView.textContainer {
                let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: removed), actualCharacterRange: nil)
                removedHeight = manager.boundingRect(forGlyphRange: glyphs, in: container).height
            }
            storage.deleteCharacters(in: NSRange(location: 0, length: removed))
            rendered.removeFirst(index)
        }
        let same = zip(rendered, entries).prefix { $0 == $1 }.count
        let prefixLength = rendered.prefix(same).reduce(0) { $0 + $1.text.utf16.count }
        storage.replaceCharacters(in: NSRange(location: prefixLength, length: storage.length - prefixLength),
                                  with: entries.dropFirst(same).map(\.text).joined())
        storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                               .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: storage.length))
        rendered = entries
        let start = min(max(0, selection.location - removed), storage.length)
        let end = min(max(start, NSMaxRange(selection) - removed), storage.length)
        textView.setSelectedRange(NSRange(location: start, length: end - start))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if following { follow() }
        else {
            contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y - removedHeight)))
            reflectScrolledClipView(contentView)
        }
        updateLatestButton()
    }
}

@MainActor
final class ActivityLogTextView: NSTextView {
    var activityMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { activityMenu?() }
}

@MainActor
private final class ActivityEmptyLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A dark floating frame with a close button and a title, around a preview or a log.
@MainActor public final class AnnotationPreviewFrame: NSVisualEffectView {
    private let title = NSTextField(labelWithString: "")
    public var filename: String {
        get { title.stringValue }
        set { title.stringValue = newValue }
    }

    public init(content: NSView, filename: String, kindLabel: String = "Annotation", closeHint: String = "Close Preview (Esc or ⌘W)",
         closeLabel: String = "Close Preview") {
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .behindWindow; state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 18; layer?.masksToBounds = true
        layer?.borderWidth = 1; layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let header = AnnotationPreviewHeader()
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: closeLabel)!,
                             target: header, action: #selector(AnnotationPreviewHeader.closePreview))
        close.isBordered = false; close.contentTintColor = .secondaryLabelColor
        close.toolTip = closeHint; close.setAccessibilityLabel(closeLabel)
        title.stringValue = filename
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kind = NSTextField(labelWithString: kindLabel)
        kind.font = .systemFont(ofSize: 11, weight: .medium); kind.textColor = .secondaryLabelColor
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let inset = NSView(); inset.wantsLayer = true
        inset.layer?.cornerRadius = 13; inset.layer?.masksToBounds = true
        for child in [header, inset] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        for child in [close, title, kind] { header.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        inset.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 36),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18), close.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: kind.leadingAnchor, constant: -16),
            kind.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            kind.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            inset.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            inset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            inset.topAnchor.constraint(equalTo: header.bottomAnchor), inset.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            content.leadingAnchor.constraint(equalTo: inset.leadingAnchor), content.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
            content.topAnchor.constraint(equalTo: inset.topAnchor), content.bottomAnchor.constraint(equalTo: inset.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor private final class AnnotationPreviewHeader: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
    @objc func closePreview() { window?.performClose(nil) }
}
