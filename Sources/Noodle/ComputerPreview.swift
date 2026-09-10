import AppKit
import ComputerBridge
import SwiftTerm
import SwiftUI

/// Uses the attachment's existing selection/click/Space entry point. Quick Look
/// cannot accept a terminal's keyboard input, so only live computers use this panel.
@MainActor final class ComputerPreviewController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var connection: ComputerPreviewTerminal?
    private var web: ComputerPreviewWeb?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private var presentedCard: ComputerCard?

    func show(_ card: ComputerCard, controller: ComputerController) {
        if presentedCard == card, let panel { panel.makeKeyAndOrderFront(nil); return }
        close()
        sourceWindow = NSApp.keyWindow
        sourceResponder = sourceWindow?.firstResponder
        let panel = ComputerPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = card.computer.name
        panel.identifier = NSUserInterfaceItemIdentifier("NoodleComputerPreview")
        panel.minSize = NSSize(width: 480, height: 320)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        // Quick Look-style chrome, but retain a normal key-capable panel for input.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let content: NSView
        if card.view == "web" {
            let web = ComputerPreviewWeb(card: card, controller: controller)
            self.web = web; content = web.surface
            web.start()
        } else {
            let connection = ComputerPreviewTerminal(card: card, controller: controller)
            self.connection = connection; content = connection.surface
        }
        panel.contentView = ComputerPreviewFrame(content: content, name: card.computer.name,
                                                symbol: card.computer.symbol, web: card.view == "web")
        ComputerPreviewGeometry.restore(panel, preferredScreen: sourceWindow?.screen)
        self.panel = panel; presentedCard = card
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        if let connection { panel.makeFirstResponder(connection.view); connection.start() }
    }
    func close() { panel?.close() }
    func integrationTestWebState() async -> String? { await web?.integrationTestState() }
    func windowDidResize(_ notification: Notification) { saveGeometry(notification) }
    func windowDidMove(_ notification: Notification) { saveGeometry(notification) }
    private func saveGeometry(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        ComputerPreviewGeometry.save(window)
    }
    func windowWillClose(_ notification: Notification) {
        saveGeometry(notification)
        connection?.stop(); connection = nil; panel = nil; presentedCard = nil
        web?.stop(); web = nil
        sourceWindow?.makeKeyAndOrderFront(nil)
        if let sourceResponder { sourceWindow?.makeFirstResponder(sourceResponder) }
        sourceWindow = nil; sourceResponder = nil
    }
}

/// Native material supplies desktop blur and respects Reduce Transparency.
/// Both terminal and web surfaces share this exact frame and clipping geometry.
@MainActor private final class ComputerPreviewFrame: NSVisualEffectView {
    init(content: NSView, name: String, symbol: String, web: Bool) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let header = ComputerPreviewHeader()
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Preview")!,
                             target: header, action: #selector(ComputerPreviewHeader.closePreview))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Close Preview (⌘W)"
        close.setAccessibilityLabel("Close Preview")
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                              ?? NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kind = NSTextField(labelWithString: web ? "Live Display" : "Live Terminal")
        kind.font = .systemFont(ofSize: 11, weight: .medium)
        kind.textColor = .secondaryLabelColor
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let inset = NSView()
        inset.wantsLayer = true
        inset.layer?.cornerRadius = 13
        inset.layer?.masksToBounds = true
        for child in [header, inset] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        for child in [close, icon, title, kind] { header.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        inset.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18), close.heightAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: kind.leadingAnchor, constant: -16),
            kind.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            kind.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            inset.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            inset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            inset.topAnchor.constraint(equalTo: header.bottomAnchor),
            inset.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            content.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
            content.topAnchor.constraint(equalTo: inset.topAnchor),
            content.bottomAnchor.constraint(equalTo: inset.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor private final class ComputerPreviewHeader: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Labels and symbols are drag handles; the close button remains clickable.
        return hit is NSButton ? hit : self
    }
    @objc func closePreview() { window?.performClose(nil) }
}

private final class ComputerPreviewPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class ComputerPreviewTerminal: NSObject, @preconcurrency TerminalViewDelegate {
    let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    let surface = NSView()
    private let status = NSTextField(labelWithString: "Connecting…")
    private let card: ComputerCard
    private let controller: ComputerController
    private lazy var download = ComputerPreviewDownload { [controller] in try await controller.openDownload() }
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var input = AsyncStream<ComputerRequest>.makeStream()
    private var active = false
    private var acceptingInput = false
    private var pendingBytes = 0
    private var dimensions = (0, 0)

    init(card: ComputerCard, controller: ComputerController) {
        self.card = card; self.controller = controller
        super.init()
        view.terminalDelegate = self
        let background = NSColor(calibratedWhite: 0.12, alpha: 1)
        view.nativeBackgroundColor = background; view.nativeForegroundColor = .white
        view.setAccessibilityLabel("Live terminal for \(card.computer.name)")
        surface.wantsLayer = true; surface.layer?.backgroundColor = background.cgColor
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)
        for child in [view, status] { surface.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            view.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8)
        ])
        download.install(in: surface)
    }
    private func request(_ operation: ComputerOperation, data: Data? = nil, offset: Int64? = nil,
                         columns: Int? = nil, rows: Int? = nil) -> ComputerRequest {
        .init(operation, computerID: card.computer.id, agentID: card.agentID,
              terminalID: card.terminalID, data: data, offset: offset, columns: columns, rows: rows)
    }
    func start() {
        active = true
        reader = Task { [weak self] in
            var offset: Int64 = 0
            while !Task.isCancelled {
                guard let self, self.active else { return }
                do {
                    let response = try await controller.previewCall(request(.terminalRead, offset: offset), card: card)
                    guard active, !Task.isCancelled else { return }
                    if response.truncated == true { view.feed(text: "\r\n[Earlier output is no longer retained.]\r\n") }
                    if let data = response.data { view.feed(byteArray: Array(data)[...]) }
                    offset = response.offset ?? offset
                    acceptingInput = response.exited != true
                    status.stringValue = acceptingInput
                        ? "Live shared terminal · Closing this preview leaves the shell running · ⌘W to close"
                        : "This shell has exited. The agent can open a new terminal; this computer is still available."
                    if response.exited == true, (response.data?.count ?? 0) == 0 { return }
                } catch {
                    guard active else { return }
                    acceptingInput = false; status.stringValue = error.localizedDescription
                    download.showIfNeeded(controller.permits(card) && !controller.installed)
                    return // Reopening retries reads, never uncertain input.
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let stream = input.stream
        writer = Task { [weak self] in
            for await request in stream {
                guard let self, self.active, !Task.isCancelled else { return }
                pendingBytes -= request.data?.count ?? 0
                do { _ = try await controller.previewCall(request, card: card) }
                catch {
                    guard active else { return }
                    acceptingInput = false; reader?.cancel()
                    status.stringValue = "Input was not retried: \(error.localizedDescription)"
                    download.showIfNeeded(controller.permits(card) && !controller.installed)
                    return
                }
            }
        }
        let terminal = view.getTerminal()
        sizeChanged(source: view, newCols: terminal.cols, newRows: terminal.rows)
    }
    func stop() {
        active = false; acceptingInput = false
        download.stop()
        reader?.cancel(); writer?.cancel(); input.continuation.finish()
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard acceptingInput, pendingBytes + data.count <= 65_536 else { NSSound.beep(); return }
        pendingBytes += data.count
        input.continuation.yield(request(.terminalWrite, data: Data(data)))
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard active else { return }
        let next = (max(1, min(500, newCols)), max(1, min(200, newRows)))
        guard next != dimensions else { return }; dimensions = next
        input.continuation.yield(request(.terminalResize, columns: next.0, rows: next.1))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    deinit { reader?.cancel(); writer?.cancel(); input.continuation.finish() }
}

struct ComputerAttachmentCard: View {
    let card: ComputerCard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Color.black
                if let data = card.previewImage, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 280, height: 165)
                } else if card.view == "web" {
                    Image(systemName: card.computer.symbol).font(.system(size: 48)).foregroundStyle(.secondary)
                        .frame(width: 280, height: 165)
                } else {
                    Text(card.terminalPreview.isEmpty ? "$" : card.terminalPreview)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white)
                    .lineLimit(10).padding(12)
                }
            }.frame(width: 280, height: 165).clipShape(RoundedRectangle(cornerRadius: 13))
            HStack(spacing: 8) {
                if let data = card.computer.icon, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(Circle())
                } else {
                    Image(systemName: card.computer.symbol).frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.25), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.computer.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text("\(card.view == "web" ? "Display" : "Terminal") preview · \(card.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }.frame(width: 280)
    }
}
