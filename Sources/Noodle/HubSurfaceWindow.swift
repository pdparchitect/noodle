import AppKit
import HubLink
import NoodleHubClient
import NoodleRuntimeSettings
import NoodletRuntime
import os
import SwiftUI

/// A card in a Hub bot's conversation, opened live.
struct HubSurfaceTarget: Hashable {
    let conversationID: UUID
    let attachmentID: UUID
    let title: String
    /// A noodlet, which may run on this Mac instead.
    var noodlet = false
}

/// Live views open floating, in the same dark frame as previews, one panel per link. Escape
/// belongs to what is shown; the close button and ⌘W close the panel, which ends the view.
@MainActor final class HubSurfacePanels: NSObject, NSWindowDelegate {
    private var panels: [HubSurfaceTarget: NSPanel] = [:]
    private var runs: [HubSurfaceTarget: HubNoodletRun] = [:]
    private var annotations: [HubSurfaceTarget: ConversationAnnotationController] = [:]

    func panel(for target: HubSurfaceTarget) -> NSPanel? { panels[target] }
    func annotations(for target: HubSurfaceTarget) -> ConversationAnnotationController? { annotations[target] }

    /// Opens a live view, or a noodlet `at` the place the person asked for, if they did.
    func open(_ target: HubSurfaceTarget, store: NoodleStore, at place: NoodletManifest.Placement? = nil) {
        if let panel = panels[target] {
            if let place { runs[target]?.choose(place) }
            return panel.makeKeyAndOrderFront(nil)
        }
        let panel = HubSurfacePanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.collectionBehavior = [.fullScreenAuxiliary, .fullScreenDisallowsTiling]
        panel.minSize = NSSize(width: 480, height: 340)
        panel.title = target.title
        let annotations = ConversationAnnotationController()
        annotations.configure(conversationID: target.conversationID, title: target.title,
            kind: target.noodlet ? "Noodlet" : "Live View", save: { [weak store] note, content, source, raw in
                try store?.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
            })
        if target.noodlet {
            let run = HubNoodletRun(target: target, requested: place)
            runs[target] = run
            let content = NSHostingView(rootView: HubNoodletView(run: run).environment(store).preferredColorScheme(.dark))
            content.sizingOptions = []
            let place = NSHostingView(rootView: HubNoodletSwitch(run: run))
            place.appearance = NSAppearance(named: .darkAqua)
            // It sits in the transparent title bar, whose safe area would push it below the header line.
            place.safeAreaRegions = []
            panel.contentView = AnnotationPreviewFrame(content: content, filename: target.title, kindLabel: "Noodlet",
                closeHint: "Close Noodlet (⌘W)", closeLabel: "Close Noodlet", accessory: place)
        } else {
            let content = NSHostingView(rootView: HubSurfaceWindow(target: target).environment(store).preferredColorScheme(.dark))
            content.sizingOptions = []
            panel.contentView = AnnotationPreviewFrame(content: content, filename: target.title, kindLabel: "Live",
                closeHint: "Close Live View (⌘W)", closeLabel: "Close Live View")
        }
        let screen = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        var frame = panel.frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
        panel.setFrame(frame, display: false)
        panel.delegate = self
        panels[target] = panel
        self.annotations[target] = annotations
        annotations.attach(to: panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel,
              let target = panels.first(where: { $0.value === closing })?.key else { return }
        panels[target] = nil
        runs[target] = nil
        annotations[target]?.attach(to: nil)
        annotations[target] = nil
        // Dropping the content ends the view, so the bot may go on.
        closing.contentView = nil
    }
}

private final class HubSurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shows what a link points at on the Hub's Mac as live video, and passes on what the person
/// does over the same channel. Closing its panel ends it, and the bot may go on.
struct HubSurfaceWindow: View {
    @Environment(NoodleStore.self) private var store
    let target: HubSurfaceTarget
    @State private var feed = SurfaceFeed()
    @State private var channel: LinkChannel?
    @State private var showing = false
    @State private var failure: String?
    /// The keys a game declared, for a controller in hand to play.
    @State private var controls: Gamepad?

    var body: some View {
        ZStack {
            SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
            if !showing {
                if let failure { Text(failure).foregroundStyle(.secondary).padding() }
                else { ProgressView() }
            }
        }
        .background(.black)
        .background(ControllerInput(controls: controls) { change in
            channel?.send(LinkSurface.control(.input(.hold(key: change.key, pressed: change.pressed))))
        })
        .task { await follow() }
        .onDisappear { channel?.cancel() }
    }

    private func follow() async {
        guard let mirror = store.hubMirror(forConversation: target.conversationID) else {
            failure = "Join that Noodle Hub again to open this."
            return
        }
        feed.onFirstPicture = { showing = true }
        do {
            let channel = try await mirror.openSurface(attachment: target.attachmentID, in: target.conversationID)
            self.channel = channel
            defer { channel.cancel() }
            for try await frame in channel.frames {
                switch LinkSurface.message(frame) {
                case .packets(let packets)?: feed.receive(packets)
                case .failed(let reason)?: failure = reason; showing = false
                case .controls(let gamepad)?: controls = gamepad
                default: break
                }
            }
            if !showing { failure = "The Hub could not show this." }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Where a Hub's noodlet in a panel runs: on this Mac, or watched live from the Hub, where the person
/// last chose or its bot suggested. A Hub from before Macs ran its noodlets always shows them live.
@MainActor @Observable final class HubNoodletRun {
    let target: HubSurfaceTarget
    private(set) var readied: (session: LinkNoodletSession, noodlet: LinkNoodlet, manifest: NoodletManifest)?
    private(set) var place: NoodletManifest.Placement?
    private(set) var failure: String?
    /// Where the person asked for it from its card's menu, until it is readied.
    private var requested: NoodletManifest.Placement?
    @ObservationIgnored private let places = NoodletPlaces()

    init(target: HubSurfaceTarget, requested: NoodletManifest.Placement? = nil) {
        self.target = target
        self.requested = requested
    }

    func ready(from mirror: HubMirror?) async {
        guard let mirror else { return failure = "Join that Noodle Hub again to open this." }
        do {
            let session = try await mirror.openNoodlet(attachment: target.attachmentID, in: target.conversationID)
            let noodlet = await session.noodlet
            let manifest = try JSONDecoder().decode(NoodletManifest.self, from: noodlet.manifest)
            readied = (session, noodlet, manifest)
            if let requested { places.choose(requested, for: noodlet.noodletID) }
            place = manifest.placement(chosen: places.chosen(noodlet.noodletID))
        } catch let error as LinkError where error.message == LinkProtocol.unknownRequest {
            place = .hub
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The other place it can run, if any.
    var otherPlace: NoodletManifest.Placement? {
        guard let readied, readied.manifest.streams, let place else { return nil }
        return place == .hub ? .device : .hub
    }

    /// Runs it at `next` from now on, as far as it can run there.
    func choose(_ next: NoodletManifest.Placement) {
        guard let readied else { return requested = next }
        places.choose(next, for: readied.noodlet.noodletID)
        place = readied.manifest.placement(chosen: next)
    }
}

/// Switches a panel's noodlet between this Mac and the Hub.
struct HubNoodletSwitch: View {
    let run: HubNoodletRun

    var body: some View {
        if let other = run.otherPlace {
            Button(other == .hub ? "Run on Hub" : "Run on This Mac") { run.choose(other) }
                .buttonStyle(.link).font(.system(size: 11, weight: .medium))
        }
    }
}

struct HubNoodletView: View {
    @Environment(NoodleStore.self) private var store
    let run: HubNoodletRun

    var body: some View {
        switch run.place {
        case .hub?: HubSurfaceWindow(target: run.target)
        case .device?:
            if let readied = run.readied {
                HubNoodletPage(mirror: store.hubMirror(forConversation: run.target.conversationID),
                               session: readied.session, noodlet: readied.noodlet).id(readied.noodlet.grant)
            }
        case nil:
            Group {
                if let failure = run.failure { Text(failure).foregroundStyle(.secondary).padding() } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .task { await run.ready(from: store.hubMirror(forConversation: run.target.conversationID)) }
        }
    }
}

/// A Hub's noodlet run on this Mac. Its files come from the Hub once for each revision; its data
/// and secrets stay there, each call going back.
struct HubNoodletPage: View {
    let mirror: HubMirror?
    let session: LinkNoodletSession
    let noodlet: LinkNoodlet
    @State private var page: NoodletPage?
    @State private var host: NoodletDeviceHost?
    @State private var failure: String?
    @State private var controls: Gamepad?

    /// The colour the noodlet asks for until its page paints, from what the Hub sent.
    private var manifestBackground: Color? {
        (try? JSONDecoder().decode(NoodletManifest.self, from: noodlet.manifest))?.backgroundColor
            .flatMap(NoodletPage.colour).map(Color.init)
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Noodle", category: "Noodlets")

    var body: some View {
        ZStack {
            if let page { NoodletPageView(page) }
            if page == nil {
                if let failure { Text(failure).foregroundStyle(.secondary).padding() } else { ProgressView() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(manifestBackground ?? .black)
        .background(ControllerInput(controls: controls, onKey: press))
        .task { await start() }
        .onDisappear { page?.stop() }
    }

    private func start() async {
        guard let mirror else { return failure = "Join that Noodle Hub again to open this." }
        do {
            let session = session
            let root = try await NoodletCache(root: mirror.noodletCache).package(
                noodlet.noodletID, revision: noodlet.revision, byteCount: noodlet.byteCount
            ) { try await session.archive(from: $0) }
            // The files it came with say how it runs; the Hub's copy of the manifest only chose where.
            let manifest = try JSONDecoder().decode(NoodletManifest.self, from: Data(contentsOf: root.appendingPathComponent("noodlet.json")))
            try manifest.validate()
            // What it declares is asked once on this Mac, as Noodle Applet asks for its own.
            let grants = NoodletGrants()
            if grants.needsAsking(manifest, id: noodlet.noodletID) {
                let alert = NSAlert()
                alert.messageText = NoodletGrants.question(manifest)
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Don’t Allow")
                guard alert.runModal() == .alertFirstButtonReturn else { return failure = NoodletGrants.refusal(manifest) }
                grants.allow(manifest, id: noodlet.noodletID)
            }
            let store = RemoteNoodletStore(send: { try await session.call(id: $0, offset: $1, total: $2, data: $3) },
                                           renew: { try await session.renew(after: $0) })
            let page = NoodletPage(root: root, manifest: manifest, store: store, dataStore: .nonPersistent(),
                                   features: NoodletDeviceHost.features,
                                   localNetwork: manifest.permissions?.contains("local-network") == true,
                                   log: { Self.log.notice("\($0, privacy: .public): \($1, privacy: .private)") })
            page.declaredCapture = .grant
            host = NoodletDeviceHost(page)
            page.failed = { failure = $0; self.page = nil }
            self.page = page
            controls = manifest.controls
            try await page.load()
        } catch {
            page?.stop()
            page = nil
            failure = error.localizedDescription
        }
    }

    /// A key the controller holds or lets go, as the key events a keyboard gives the page.
    private func press(_ change: GamepadKeyChange) {
        guard let page, let script = PageKeys.script(for: .hold(key: change.key, pressed: change.pressed)) else { return }
        Task { _ = try? await page.evaluate(script) }
    }
}

/// Plays the keys a game declared from a controller in hand while its panel is in front. The
/// Mac's keyboard has the same keys, so nothing goes on the screen.
private struct ControllerInput: NSViewRepresentable {
    let controls: Gamepad?
    let onKey: (GamepadKeyChange) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onKey = onKey
        probe.controls = controls
    }

    static func dismantleNSView(_ probe: Probe, coordinator: ()) { probe.gamepad.detach() }

    final class Probe: NSView {
        let gamepad = HardwareGamepad()
        var onKey: (GamepadKeyChange) -> Void = { _ in }
        var controls: Gamepad? {
            didSet { if controls != oldValue { follow() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            follow()
        }

        private func follow() {
            guard let controls, let window else { return gamepad.detach() }
            gamepad.attach(controls, in: window) { [weak self] in self?.onKey($0) }
        }
    }
}
