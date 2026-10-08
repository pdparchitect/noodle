import AVFAudio
import HubLink
import NoodletRuntime
import os
import SwiftUI
import WebKit

/// Whether the on-screen game controls tap back under the thumb; off until the person turns it on.
enum ScreenControlHaptics {
    static let key = "screenControlHaptics"
}

/// A noodlet opened from a conversation, which the controller's View button can swap for another
/// of the conversation's noodlets while it plays on the TV, without closing.
struct NoodletPlayer: View {
    let chats: HubChats
    let thread: HubThread
    /// The conversation's noodlets, newest first.
    let choices: [LinkAttachment]
    @State var playing: LinkAttachment
    /// Where the person asked to open the first one, if they did.
    @State var requested: NoodletManifest.Placement?
    /// The choices with their pictures and names, as the conversation's cards show them.
    @State private var fetched: [UUID: LinkAttachment] = [:]

    var body: some View {
        NoodletScreen(chats: chats, thread: thread, attachment: playing, requested: requested)
            .id(playing.id)
            .environment(\.noodletMenu, NoodletMenu(choices: Self.shown(choices, fetched: fetched), current: playing.id) { next in
                requested = nil
                playing = next
            })
            .task {
                for choice in choices where fetched[choice.id] == nil {
                    fetched[choice.id] = await chats.sharedAttachment(choice, in: thread)
                }
            }
    }

    /// Shared links carry no card, so each shows as fetched once it is.
    static func shown(_ choices: [LinkAttachment], fetched: [UUID: LinkAttachment]) -> [LinkAttachment] {
        choices.map { fetched[$0.id] ?? $0 }
    }

    /// Controller presses are not touches, so iOS would dim and lock the phone mid-game.
    static func keepsAwake(onTV: Bool, controllerConnected: Bool) -> Bool { onTV || controllerConnected }
}

/// A noodlet a bot shared: run on this phone, or watched live from the Hub, where the person last
/// chose or its bot suggested. A Hub from before phones ran noodlets always shows it live.
struct NoodletScreen: View {
    let chats: HubChats
    let thread: HubThread
    let attachment: LinkAttachment
    /// Where the person asked to open it from its card's menu, remembered for next time.
    var requested: NoodletManifest.Placement?
    var places = NoodletPlaces()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeNoodlet) private var closeNoodlet
    @State private var readied: (session: LinkNoodletSession, noodlet: LinkNoodlet, manifest: NoodletManifest)?
    @State private var place: NoodletManifest.Placement?
    @State private var failure: String?

    var body: some View {
        switch place {
        case .hub?:
            LiveSurfaceScreen(chats: chats, thread: thread, attachment: attachment,
                              runHere: readied.map { _ in { choose(.device) } })
        case .device?:
            if let readied {
                NoodletDeviceScreen(chats: chats, session: readied.session, noodlet: readied.noodlet, manifest: readied.manifest,
                                    title: attachment.card?.title ?? readied.manifest.title,
                                    runOnHub: readied.manifest.streams ? { choose(.hub) } : nil)
            }
        case nil:
            NavigationStack {
                Group {
                    if let failure { Text(failure).foregroundStyle(.secondary).padding() } else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) } }
            }
            .task { await ready() }
        }
    }

    /// Back to where it was opened from: the conversation, or the console's shelves.
    private func close() { if let closeNoodlet { closeNoodlet() } else { dismiss() } }

    private func ready() async {
        do {
            let session = try await chats.openNoodlet(attachment, in: thread)
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

    private func choose(_ next: NoodletManifest.Placement) {
        if let readied { places.choose(next, for: readied.noodlet.noodletID) }
        place = next
    }
}

/// A noodlet's page run on this phone. Its files come from the Hub once for each revision; its
/// data and secrets stay there, each call going back.
struct NoodletDeviceScreen: View {
    let chats: HubChats
    let session: LinkNoodletSession
    let noodlet: LinkNoodlet
    let manifest: NoodletManifest
    let title: String
    /// For a noodlet the Hub may stream, switches to watching it there.
    let runOnHub: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeNoodlet) private var closeNoodlet
    @Environment(\.verticalSizeClass) private var verticalSize
    @AppStorage(ScreenControlHaptics.key) private var haptics = false
    @State private var page: NoodletPage?
    @State private var host: NoodletDeviceHost?
    @State private var failure: String?
    @State private var showsControls = true
    @State private var hardware = HardwareGamepad()
    /// A game brought back from the TV to the phone.
    @State private var onPhone = false
    /// A game reading controllers through the Gamepad API, whose buttons then no longer press its keys too.
    @State private var readsControllers = false
    @State private var tvAvailable = false
    @State private var connectingTV = false
    @State private var gameMenu = GameMenu()
    @Environment(\.noodletMenu) private var noodletMenu
    /// What the noodlet declares, while the person is asked about it.
    @State private var asking: (manifest: NoodletManifest, answer: CheckedContinuation<Bool, Never>)?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleMobile", category: "Noodlets")

    /// Sideways, or for a noodlet that asks for the whole screen, the page gets it and the
    /// buttons float over its corners.
    private var fullScreen: Bool { verticalSize == .compact || manifest.display == .fullscreen || onTV }

    /// A game plays on a connected TV, and the phone is its controller.
    private var onTV: Bool { page != nil && ExternalScreen.plays(manifest.controls, available: tvAvailable, onPhone: onPhone) }

    /// A page laid out for a desktop window gets the desktop site, as in Safari, unless it presents
    /// itself as an app, which fits the phone's view.
    static func contentMode(for manifest: NoodletManifest) -> WKWebpagePreferences.ContentMode {
        (manifest.layout ?? .desktop) == .desktop && manifest.display?.fitsView != true ? .desktop : .mobile
    }

    /// `readsControllers` is called once the page asks for controllers through the Gamepad API.
    static func configure(_ configuration: WKWebViewConfiguration, for manifest: NoodletManifest, readsControllers: @escaping () -> Void = {}) {
        configuration.defaultWebpagePreferences.preferredContentMode = contentMode(for: manifest)
        // A game played from the on-screen controls never has its page tapped, which iOS otherwise
        // waits for before letting it make a sound.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // WebKit gives Web Audio a category that Silent Mode mutes; playback is heard either way,
        // as a video app is.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "if (navigator.audioSession) navigator.audioSession.type = 'playback';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if manifest.controls != nil {
            configuration.userContentController.addUserScript(WKUserScript(
                source: renderScript(consoleSize(onTV: false)), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.add(ControllerReader(found: readsControllers), contentWorld: .page, name: ControllerReader.name)
        configuration.userContentController.addUserScript(WKUserScript(
            source: ControllerReader.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// The most pixels a game draws, as a games console does: handheld on a phone, docked on an
    /// iPad or a TV. The view scales it up to fill, as a TV does a console's.
    static func consoleSize(onTV: Bool) -> (long: Int, short: Int) {
        onTV || UIDevice.current.userInterfaceIdiom == .pad ? (1920, 1080) : (1280, 720)
    }

    /// Tells the page the size it may draw at now that it moved to or from the TV.
    static func renderSize(onTV: Bool) -> String {
        let size = consoleSize(onTV: onTV)
        return "window.__noodleRenderSize?.(\(size.long), \(size.short));"
    }

    /// A game sizes its canvas by devicePixelRatio, which on a phone's screen is more than its GPU
    /// keeps up with in 3D; the ratio it reads keeps the page within the console's size.
    private static func renderScript(_ size: (long: Int, short: Int)) -> String {
        """
        (() => {
          const own = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio') ?? Object.getOwnPropertyDescriptor(Window.prototype, 'devicePixelRatio');
          const screenRatio = () => own.get.call(window);
          let most = [\(size.long), \(size.short)];
          Object.defineProperty(window, 'devicePixelRatio', { configurable: true, enumerable: true, get: () => {
            const long = Math.max(innerWidth, innerHeight), short = Math.min(innerWidth, innerHeight);
            return long && short ? Math.min(screenRatio(), most[0] / long, most[1] / short) : screenRatio();
          } });
          Object.defineProperty(window, '__noodleRenderSize', { value: (long, short) => {
            most = [long, short];
            dispatchEvent(new Event('resize'));
          } });
        })();
        """
    }

    private var screenControls: Gamepad? {
        guard let controls = manifest.controls, showsControls || onTV else { return nil }
        guard let controller = hardware.controller else { return controls }
        return controls.onScreen(with: controller)
    }

    @ViewBuilder private var buttons: some View {
        if manifest.controls != nil {
            TVButton(onTV: onTV, available: tvAvailable, onPhone: $onPhone, connecting: $connectingTV)
        }
        if !onTV {
            if manifest.controls != nil {
                Button("Controls", systemImage: showsControls ? "gamecontroller.fill" : "gamecontroller") { showsControls.toggle() }
            }
            Button("Keyboard", systemImage: "keyboard") { host?.toggleKeyboard() }
        }
        if let runOnHub { Button("Run on Hub", systemImage: "play.display", action: runOnHub) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if onTV {
                    Color.black.ignoresSafeArea()
                    if screenControls == nil { ConnectedControllersView() }
                } else if let page {
                    MovableView(view: page.web).ignoresSafeArea(edges: fullScreen ? .all : .bottom)
                }
                if let screenControls, page != nil { GamepadOverlay(gamepad: screenControls, haptics: haptics, onKey: press) }
                if !onTV { GameMenuOverlay(gameMenu: gameMenu, menu: noodletMenu).ignoresSafeArea() }
                if page == nil {
                    if let failure { Text(failure).foregroundStyle(.secondary).padding() } else { ProgressView() }
                }
            }
            // The whole screen even while loading, so the buttons over it start in its corners.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Under the buttons that float over the top corners of a full-screen page.
            .overlay(alignment: .topTrailing) { SurfaceNoticeView(onTV ? nil : page?.activity.notice).padding(.top, fullScreen ? 44 : 0) }
            .overlay(alignment: .top) {
                if fullScreen {
                    HStack {
                        Button("Done", action: close)
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
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
                ToolbarItemGroup(placement: .primaryAction) { buttons }
            }
        }
        .background(manifest.backgroundColor.flatMap(NoodletPage.colour).map(Color.init) ?? Color(.systemBackground))
        .alert(asking.map { NoodletGrants.question($0.manifest) } ?? "", isPresented: .constant(asking != nil)) {
            Button("Allow") { answer(true) }
            Button("Don’t Allow", role: .cancel) { answer(false) }
        }
        .externalScreen(enabled: Binding(get: { manifest.controls != nil && !onPhone }, set: { onPhone = !$0 }),
                        available: $tvAvailable) {
            if let page { MovableView(view: page.web) }
            GameMenuOverlay(gameMenu: gameMenu, menu: noodletMenu)
        }
        .tvConnectionAlert(isPresented: $connectingTV)
        .task { await start() }
        .onAppear { gameMenu.follow(hardware: hardware, menu: { noodletMenu }, close: close) }
        // The phone turns sideways as a controller does.
        .onChange(of: onTV, initial: true) {
            ScreenOrientation.hold(onTV ? .landscape : manifest.orientation)
            if let page {
                Task {
                    _ = try? await page.evaluate(Self.renderSize(onTV: onTV))
                    // Moving to the other screen takes the first responder from it.
                    page.web.becomeFirstResponder()
                }
            }
        }
        .onChange(of: NoodletPlayer.keepsAwake(onTV: onTV, controllerConnected: hardware.hasController), initial: true) { _, awake in
            KeepAwake.set(awake)
        }
        .onDisappear {
            answer(false); hardware.detach(); page?.stop(); NoodletSound.stop(); ScreenOrientation.hold(nil)
            KeepAwake.set(false)
        }
    }

    /// Back to where it was opened from: the conversation, or the console's shelves.
    private func close() { if let closeNoodlet { closeNoodlet() } else { dismiss() } }

    private func answer(_ allowed: Bool) {
        let pending = asking
        asking = nil
        pending?.answer.resume(returning: allowed)
    }

    private func start() async {
        do {
            let session = session
            let root = try await NoodletCache(root: chats.noodletCache).package(
                noodlet.noodletID, revision: noodlet.revision, byteCount: noodlet.byteCount
            ) { try await session.archive(from: $0) }
            // The files it came with say how it runs; the Hub's copy of the manifest only chose where.
            let manifest = try JSONDecoder().decode(NoodletManifest.self, from: Data(contentsOf: root.appendingPathComponent("noodlet.json")))
            try manifest.validate()
            // What it declares is asked once on this phone, and kept until taken back in Settings.
            let grants = NoodletGrants()
            if grants.needsAsking(manifest, id: noodlet.noodletID) {
                guard await withCheckedContinuation({ asking = (manifest, $0) }) else { return failure = NoodletGrants.refusal(manifest) }
                grants.allow(manifest, id: noodlet.noodletID)
            }
            let store = RemoteNoodletStore(send: { try await session.call(id: $0, offset: $1, total: $2, data: $3) },
                                           renew: { try await session.renew(after: $0) })
            let page = NoodletPage(root: root, manifest: manifest, store: store, dataStore: .nonPersistent(),
                                   features: NoodletDeviceHost.features,
                                   localNetwork: manifest.permissions?.contains("local-network") == true, log: { Self.log.notice("\($0, privacy: .public): \($1, privacy: .private)") }) {
                Self.configure($0, for: manifest) { readsControllers = true }
            }
            page.declaredCapture = .grant
            #if DEBUG
            // Safari's Web Inspector on the Mac reaches a development build's noodlets, to profile them.
            page.web.isInspectable = true
            #endif
            host = NoodletDeviceHost(page)
            page.failed = { failure = $0; self.page = nil }
            self.page = page
            NoodletSound.start()
            // A noodlet with no keys still gets the View button's menu; its other buttons stay its own.
            hardware.attach(manifest.controls ?? Gamepad(), onKey: { if !readsControllers { press($0) } })
            try await page.load()
            // WebKit gives the Gamepad API controllers only while its view is the first responder.
            page.web.becomeFirstResponder()
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

/// Tells the app once a page asks for controllers through the Gamepad API: a game that does reads
/// them itself from the first press, which would otherwise reach it as a key as well.
final class ControllerReader: NSObject, WKScriptMessageHandler {
    static let name = "noodleControllers"
    static let script = """
        (() => {
          let asked = false;
          navigator.getGamepads = function () {
            if (!asked) {
              asked = true;
              window.webkit.messageHandlers.\(name).postMessage(true);
            }
            return Navigator.prototype.getGamepads.call(navigator);
          };
        })();
        """
    private let found: () -> Void

    init(found: @escaping () -> Void) { self.found = found }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { found() }
}

/// A noodlet's sound, heard while it is open even with the ring switch set to silent, as a game
/// is, and alongside whatever else is playing.
@MainActor enum NoodletSound {
    static func start() {
        // Calls and voice recordings own the shared session until they finish.
        guard AVAudioSession.sharedInstance().category != .playAndRecord else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    static func stop() {
        guard AVAudioSession.sharedInstance().category != .playAndRecord else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
    }
}

/// Which ways the phone may turn: any, except while a noodlet that asks for one way is open.
@MainActor enum ScreenOrientation {
    static private(set) var allowed: UIInterfaceOrientationMask = .all
    /// The way it turns once no noodlet holds it, such as sideways while the console is open.
    static var resting: NoodletManifest.Orientation?

    static func mask(for orientation: NoodletManifest.Orientation?) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait?: .portrait
        case .landscape?: .landscape
        case .any?, nil: .all
        }
    }

    static func hold(_ orientation: NoodletManifest.Orientation?) {
        allowed = mask(for: orientation ?? resting)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: allowed))
        }
    }
}

/// Keeps the phone from dimming and locking, while a noodlet needs it or the console is open.
@MainActor enum KeepAwake {
    static var resting = false

    static func set(_ awake: Bool) { UIApplication.shared.isIdleTimerDisabled = awake || resting }
}

extension AppDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ScreenOrientation.allowed
    }
}
