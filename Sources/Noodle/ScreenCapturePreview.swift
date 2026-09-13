import AppKit
import SwiftUI
import NoodleCore

/// Keeps the shortcut scoped to the chat window, including sidebar focus.
struct CaptureShortcut: NSViewRepresentable {
    let capture: () -> Void
    func makeNSView(context: Context) -> CaptureShortcutView { CaptureShortcutView() }
    func updateNSView(_ view: CaptureShortcutView, context: Context) { view.capture = capture }
    static func dismantleNSView(_ view: CaptureShortcutView, coordinator: ()) { view.stop(); view.capture = nil }
}

@MainActor final class CaptureShortcutView: NSView {
    var capture: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, NSApp.keyWindow === window, let capture,
              NSApp.modalWindow == nil, window.attachedSheet == nil, window.sheetParent == nil,
              KeyboardBindings.shared.matches(.capture, event: event) else { return event }
        if !event.isARepeat { capture() }
        return nil
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

@MainActor final class ScreenCapturePreviewController: NSObject, NSWindowDelegate, PreviewAnnotationTarget {
    private(set) var panel: ScreenCapturePanel?
    private(set) var model: ScreenCaptureModel?
    private weak var host: NSWindow?
    private weak var responder: NSResponder?

    func show(kind: ScreenCaptureKind, relativeTo host: NSWindow, service: (any ScreenCaptureProviding)? = nil,
              save: @escaping (CGImage, String, AttachmentAnnotation.Region?, String) throws -> Void) {
        if focusIfOpen() { return }
        self.host = host; responder = host.firstResponder
        let panel = ScreenCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 660),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        // Keep capture controls reachable when inspecting another desktop or a full-screen app.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .fullScreenDisallowsTiling]
        panel.title = "Screen Capture"; panel.identifier = NSUserInterfaceItemIdentifier("NoodleScreenCapture")
        panel.minSize = NSSize(width: 580, height: 440)
        panel.delegate = self
        let model = ScreenCaptureModel(kind: kind, service: service, currentDisplay: { [weak panel, weak host] in
            let screen = panel?.screen ?? host?.screen ?? NSScreen.main
            return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }, excludedWindows: { [weak panel] in
            panel.map { [CGWindowID($0.windowNumber)] } ?? []
        })
        model.onSave = save
        model.onFinish = { [weak self] in self?.close() }
        model.onCommandsChange = { [weak self] in self?.updateCommands() }
        panel.model = model
        let content = NSHostingView(rootView: ScreenCapturePreview(model: model))
        content.sizingOptions = []
        panel.contentView = AnnotationPreviewFrame(content: content, filename: "Screen Capture",
            kindLabel: "Preview", closeHint: "Close Preview (⌘W)")
        let screen = host.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? host.frame
        var frame = panel.frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
        panel.setFrame(frame, display: false)
        self.panel = panel; self.model = model
        panel.makeKeyAndOrderFront(nil)
        model.chooseSources()
    }
    @discardableResult func focusIfOpen() -> Bool {
        guard let panel else { return false }
        panel.makeKeyAndOrderFront(nil)
        return true
    }
    func close() { panel?.close() }
    func annotate() { model?.annotate() }
    func startRegion() { model?.annotate() }
    func windowDidBecomeKey(_ notification: Notification) { updateCommands() }
    func windowDidResignKey(_ notification: Notification) { updateCommands() }
    private func updateCommands() {
        let state = AnnotationCommandsState.shared
        if panel?.isKeyWindow == true {
            state.owner = self; state.enabled = model?.canCapture == true
        } else if state.owner === self { state.enabled = false }
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        let restoreFocus = closing.isKeyWindow
        model?.close(); model?.onSave = nil; model?.onFinish = nil
        model?.onCommandsChange = nil
        if AnnotationCommandsState.shared.owner === self {
            AnnotationCommandsState.shared.owner = nil; AnnotationCommandsState.shared.enabled = false
        }
        panel = nil; model = nil
        if restoreFocus {
            host?.makeKeyAndOrderFront(nil)
            if let responder { host?.makeFirstResponder(responder) }
        }
        host = nil; responder = nil
    }
}

@MainActor final class ScreenCapturePanel: NSPanel {
    var model: ScreenCaptureModel?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Keep edge resizing while disabling document-window sizing actions.
    override func zoom(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}
    override func toggleFullScreen(_ sender: Any?) {}
    override func cancelOperation(_ sender: Any?) {
        if model?.phase == .annotating { model?.retake() } else { close() }
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 51,
           event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty,
           let model, model.phase == .loading || model.phase == .live {
            if !event.isARepeat { model.chooseSources() }
            return
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let bindings = KeyboardBindings.shared
        if bindings.matches(.capture, event: event) {
            // The picker is already open; preserve its source and annotations.
            return true
        }
        if bindings.matches(.annotateRegion, event: event) || bindings.matches(.annotateSelection, event: event) {
            if !event.isARepeat { model?.annotate() }
            return true
        }
        if model?.phase == .annotating, bindings.matches(.saveAnnotation, event: event) {
            if !event.isARepeat { model?.saveAnnotation() }
            return true
        }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct ScreenCapturePreview: View {
    @Bindable var model: ScreenCaptureModel
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if model.phase == .choosing { picker }
            else {
                ZStack {
                    Color.black.opacity(0.65)
                    if let image = model.image {
                        CaptureCanvas(image: image, selecting: model.phase == .annotating, region: model.region) { region in
                            model.region = region; commentFocused = true
                        }
                        .padding(12)
                        .accessibilityLabel(model.phase == .annotating ? "Frozen capture. Drag to select an annotation region." : "Live capture preview")
                    } else if model.error == nil {
                        ProgressView("Starting live preview…")
                    } else {
                        Label("Preview unavailable", systemImage: "video.slash").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.phase == .annotating, model.region != nil {
                    Divider()
                    commentEditor
                }
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Divider()
            footer.padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissionMayHaveChanged()
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            if let source = model.source {
                Image(systemName: model.kind == .screen ? "display" : "macwindow")
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.headline).lineLimit(1)
                    Text(model.phase == .annotating ? "Drag around a detail, then add a comment." : "Capture this frame or annotate a region.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.phase == .annotating ? "Frozen" : model.phase == .live ? "Live" : model.error == nil ? "Connecting…" : "Unavailable",
                      systemImage: model.phase == .annotating ? "pause.circle.fill" : "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.phase == .live ? Color.green : Color.secondary)
            } else {
                Text("Choose what to capture").font(.headline)
                Spacer()
                Picker("Capture source", selection: $model.kind) {
                    ForEach(ScreenCaptureKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                .onChange(of: model.kind) { _, _ in model.chooseSources() }
            }
        }
    }
    @ViewBuilder private var picker: some View {
        if model.needsPermission {
            VStack(spacing: 16) {
                Image(systemName: "display").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Allow screen previews").font(.title3.weight(.semibold))
                Text("Noodle needs Screen Recording access to preview your screens and windows. Capture adds only the image you choose to your draft.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                Button("Allow Screen Capture") { model.requestPermission() }.buttonStyle(.borderedProminent)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("After enabling access, return here and click Refresh. macOS may ask you to reopen Noodle.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loadingSources && model.sources.isEmpty {
            ProgressView("Loading previews…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sources.isEmpty {
            ContentUnavailableView("No \(model.kind.rawValue.lowercased()) with a preview", systemImage: "display",
                description: Text("Open or restore a window, or connect a screen, then refresh."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    ForEach(model.sources) { source in
                        Button { model.select(source) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.15))
                                    if let thumbnail = model.thumbnails[source.id] {
                                        Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().padding(5)
                                    } else {
                                        Image(systemName: model.kind == .screen ? "display" : "macwindow")
                                            .font(.largeTitle).foregroundStyle(.secondary)
                                    }
                                }.frame(height: 145)
                                Text(source.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(source.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Preview \(source.title)")
                        .accessibilityLabel("Preview \(source.title), \(source.subtitle)")
                    }
                }.padding(18)
            }
        }
    }
    private var commentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.region == nil ? "Select a region in the image above." : "Comment")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.comment).font(.body).frame(height: 65)
                .scrollContentBackground(.hidden).padding(6)
                .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .focused($commentFocused).accessibilityLabel("Annotation comment")
                .onExitCommand { model.retake() }
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if model.phase == .choosing {
                Button("Refresh", systemImage: "arrow.clockwise") { model.chooseSources(retryUnavailable: true) }.disabled(model.loadingSources)
                if model.loadingSources { ProgressView().controlSize(.small).help("Loading previews…") }
                Spacer()
                Text(model.kind == .window
                     ? "This display first, then other desktops and full-screen windows. Largest first."
                     : "Each screen shows its active Space. Use Windows for apps in other Spaces.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Choose Another…") { model.chooseSources() }
                    .help(model.phase == .annotating ? "Choose another window or screen" : "Choose Another (⌫)")
                if model.phase == .annotating || model.error != nil { Button("Retake") { model.retake() } }
                Spacer()
                if model.phase == .annotating {
                    Text(KeyboardBindings.shared.label(for: .saveAnnotation)).font(.caption).foregroundStyle(.secondary)
                    Button("Add to Message") { model.saveAnnotation() }
                        .buttonStyle(.borderedProminent).disabled(!model.canSaveAnnotation)
                } else {
                    Button("Annotate…") { model.annotate() }.disabled(!model.canCapture)
                        .help(KeyboardBindings.shared.help("Annotate Region", for: .annotateRegion))
                    Button("Capture") { model.capture() }.buttonStyle(.borderedProminent).disabled(!model.canCapture)
                }
            }
        }
    }
}

private struct CaptureCanvas: NSViewRepresentable {
    let image: CGImage
    let selecting: Bool
    let region: AttachmentAnnotation.Region?
    let onRegion: (AttachmentAnnotation.Region) -> Void
    func makeNSView(context: Context) -> ScreenCaptureCanvas { ScreenCaptureCanvas() }
    func updateNSView(_ view: ScreenCaptureCanvas, context: Context) {
        view.image = image; view.selecting = selecting; view.region = region; view.onRegion = onRegion
        view.needsDisplay = true; view.window?.invalidateCursorRects(for: view)
    }
}

/// Selection is expressed in image coordinates, independent of letterboxing,
/// window resizing, or a display's backing scale.
@MainActor final class ScreenCaptureCanvas: NSView {
    var image: CGImage?
    var selecting = false
    var region: AttachmentAnnotation.Region?
    var onRegion: ((AttachmentAnnotation.Region) -> Void)?
    private var start: NSPoint?
    private var drag: CGRect?
    var imageRect: CGRect { Self.imageRect(imageSize: image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero, bounds: bounds) }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { if selecting { addCursorRect(imageRect, cursor: .crosshair) } }
    static func imageRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func normalizedRegion(_ rect: CGRect, in imageRect: CGRect) -> AttachmentAnnotation.Region? {
        let rect = rect.intersection(imageRect)
        guard !rect.isNull, rect.width > 0, rect.height > 0, imageRect.width > 0, imageRect.height > 0 else { return nil }
        return .init(x: (rect.minX - imageRect.minX) / imageRect.width, y: (rect.minY - imageRect.minY) / imageRect.height,
                     width: rect.width / imageRect.width, height: rect.height / imageRect.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let rect = imageRect
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: rect)
        let selected = drag ?? region.map { CGRect(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height,
                                                   width: $0.width * rect.width, height: $0.height * rect.height) }
        if selecting, let selected {
            NSColor.systemOrange.withAlphaComponent(0.14).setFill(); selected.fill()
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath(rect: selected); path.lineWidth = 3; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard selecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        window?.makeFirstResponder(self); start = point; drag = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, selecting else { return }
        let end = convert(event.locationInWindow, from: nil)
        drag = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(imageRect)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start, selecting else { return }
        let selected = (drag?.width ?? 0) < 4 || (drag?.height ?? 0) < 4
            ? CGRect(x: start.x - 8, y: start.y - 8, width: 16, height: 16) : drag!
        self.start = nil; drag = nil
        if let region = Self.normalizedRegion(selected, in: imageRect) { self.region = region; onRegion?(region) }
        needsDisplay = true
    }
}
