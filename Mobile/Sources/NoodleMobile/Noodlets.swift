import HubLink
import NoodletRuntime
import os
import SwiftUI

/// A noodlet a bot shared: run on this phone, or watched live from the Hub, where the person last
/// chose or its bot suggested. A Hub from before phones ran noodlets always shows it live.
struct NoodletScreen: View {
    let chats: HubChats
    let thread: HubThread
    let attachment: LinkAttachment
    var places = NoodletPlaces()
    @Environment(\.dismiss) private var dismiss
    @State private var readied: (noodlet: LinkNoodlet, manifest: NoodletManifest)?
    @State private var place: NoodletManifest.Placement?
    @State private var failure: String?

    var body: some View {
        switch place {
        case .hub?:
            LiveSurfaceScreen(chats: chats, thread: thread, attachment: attachment,
                              runHere: readied.flatMap { $0.manifest.runsOnDevices ? { choose(.device) } : nil })
        case .device?:
            if let readied {
                NoodletDeviceScreen(chats: chats, noodlet: readied.noodlet, manifest: readied.manifest,
                                    title: attachment.card?.title ?? readied.manifest.title) { choose(.hub) }
            }
        case nil:
            NavigationStack {
                Group {
                    if let failure { Text(failure).foregroundStyle(.secondary).padding() } else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            }
            .task { await ready() }
        }
    }

    private func ready() async {
        do {
            let noodlet = try await chats.readyNoodlet(attachment, in: thread)
            let manifest = try JSONDecoder().decode(NoodletManifest.self, from: noodlet.manifest)
            readied = (noodlet, manifest)
            place = manifest.placement(chosen: places.chosen(noodlet.noodletID))
        } catch let error as LinkError where error.message == LinkProtocol.unknownRequest {
            place = .hub
        } catch {
            failure = error.localizedDescription
        }
    }

    private func choose(_ next: NoodletManifest.Placement) {
        if let readied { places.choose(next, for: readied.noodlet.noodletID) }
        place = next
    }
}

/// A noodlet's page run on this phone. Its files come from the Hub once for each revision; its
/// data and secrets stay there, each call going back.
struct NoodletDeviceScreen: View {
    let chats: HubChats
    let noodlet: LinkNoodlet
    let manifest: NoodletManifest
    let title: String
    let runOnHub: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var page: NoodletPage?
    @State private var host: NoodletDeviceHost?
    @State private var failure: String?
    @State private var showsControls = true
    @State private var hardware = HardwareGamepad()

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleMobile", category: "Noodlets")

    /// Sideways, the page gets the whole screen and the buttons float over its corners.
    private var fullScreen: Bool { verticalSize == .compact }

    private var screenControls: Gamepad? {
        guard let controls = manifest.controls, showsControls else { return nil }
        guard let controller = hardware.controller else { return controls }
        return controls.onScreen(with: controller)
    }

    @ViewBuilder private var buttons: some View {
        if manifest.controls != nil {
            Button("Controls", systemImage: showsControls ? "gamecontroller.fill" : "gamecontroller") { showsControls.toggle() }
        }
        Button("Run on Hub", systemImage: "play.display", action: runOnHub)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let page { NoodletPageView(page).ignoresSafeArea(edges: fullScreen ? .all : .bottom) }
                if let screenControls, page != nil { GamepadOverlay(gamepad: screenControls, onKey: press) }
                if page == nil {
                    if let failure { Text(failure).foregroundStyle(.secondary).padding() } else { ProgressView() }
                }
            }
            .overlay(alignment: .top) {
                if fullScreen {
                    HStack {
                        Button("Done") { dismiss() }
                        Spacer()
                        buttons.labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass).padding(.horizontal, 12)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(fullScreen)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) { buttons }
            }
        }
        .task { await start() }
        .onDisappear { hardware.detach(); page?.stop() }
    }

    private func start() async {
        do {
            let grant = noodlet.grant, chats = chats
            let root = try await NoodletCache(root: chats.noodletCache).package(
                noodlet.noodletID, revision: noodlet.revision, byteCount: noodlet.byteCount
            ) { try await chats.noodletArchive(grant, from: $0) }
            // The files it came with say how it runs; the Hub's copy of the manifest only chose where.
            let manifest = try JSONDecoder().decode(NoodletManifest.self, from: Data(contentsOf: root.appendingPathComponent("noodlet.json")))
            try manifest.validate()
            let store = RemoteNoodletStore { id, offset, total, piece in
                try await chats.noodletCall(LinkNoodletCall(grant: grant, id: id, offset: offset, total: total, data: piece))
            }
            let page = NoodletPage(root: root, manifest: manifest, store: store, dataStore: .nonPersistent(),
                                   features: NoodletDeviceHost.features, log: { Self.log.notice("\($0, privacy: .public): \($1, privacy: .private)") }) {
                // Laid out for a desktop window, it gets desktop width and pinch to zoom, as Safari's desktop site.
                $0.defaultWebpagePreferences.preferredContentMode = (manifest.layout ?? .desktop) == .desktop ? .desktop : .mobile
            }
            host = NoodletDeviceHost(page)
            page.failed = { failure = $0; self.page = nil }
            self.page = page
            if let controls = manifest.controls { hardware.attach(controls, onKey: press) }
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
