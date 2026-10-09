import GameController
import HubLink
import SwiftUI
import UIKit
import WebKit

/// A TV the phone reaches by Screen Mirroring or a cable: an open game plays there while the
/// phone becomes its controller, and otherwise the TV mirrors the phone.
enum ExternalScreen {
    /// Whether a game with `controls` plays on the TV: while iOS has one for it, unless the
    /// person brought it back to the phone.
    static func plays(_ controls: Gamepad?, available: Bool, onPhone: Bool) -> Bool {
        available && controls != nil && !onPhone
    }
}

extension View {
    /// Offers `content` to a connected TV, which shows it while `enabled` and mirrors the phone
    /// otherwise, and keeps `available` saying whether there is a TV. iOS 27 connects a TV only
    /// for a screen that offers it.
    @ViewBuilder func externalScreen(enabled: Binding<Bool>, available: Binding<Bool>,
                                     @ViewBuilder content: @escaping () -> some View) -> some View {
        if #available(iOS 27, *) {
            sceneAccessory {
                ExternalNonInteractiveAccessory(isEnabled: enabled) {
                    ZStack {
                        Color.black
                        content()
                    }
                    .ignoresSafeArea()
                }
                .onAvailabilityChange { available.wrappedValue = $0 }
            }
        } else {
            self
        }
    }
}

/// Shows a view only one screen can hold at a time, such as a noodlet's page: the screen that
/// shows it last takes it, and the one it left going away does not take it along.
struct MovableView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> Holder {
        let holder = Holder()
        holder.hold(view)
        return holder
    }

    func updateUIView(_ holder: Holder, context: Context) {
        if holder.held !== view { holder.hold(view) }
    }

    final class Holder: UIView {
        private(set) weak var held: UIView?

        func hold(_ view: UIView) {
            held = view
            addSubview(view)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let held, held.superview === self { held.frame = bounds }
        }
    }
}

/// Moves a game between the TV and the phone, or asks for a TV when there is none.
struct TVButton: View {
    let onTV: Bool
    let available: Bool
    @Binding var onPhone: Bool
    @Binding var connecting: Bool

    var body: some View {
        if #available(iOS 27, *) {
            if onTV {
                let model = UIDevice.current.model
                Button("Show on \(model)", systemImage: model == "iPad" ? "ipad" : "iphone") { onPhone = true }
            } else {
                Button("Show on TV", systemImage: "tv") {
                    if available { onPhone = false } else { connecting = true }
                }
            }
        }
    }
}

extension View {
    func tvConnectionAlert(isPresented: Binding<Bool>) -> some View {
        alert("No TV Connected", isPresented: isPresented) {
            Button("OK") {}
        } message: {
            Text("Turn on Screen Mirroring in Control Center, or connect a TV with a cable.")
        }
    }
}

/// A game controller connected to the phone, as the phone lists it while a game plays on the TV.
struct ConnectedController: Identifiable {
    let id: ObjectIdentifier
    let name: String
    let symbol: String
    let battery: String?

    /// The game controllers among `controllers`, leaving out remotes and the like.
    static func list(_ controllers: [GCController]) -> [Self] {
        controllers.filter { $0.extendedGamepad != nil }.map { controller in
            let battery = controller.battery.flatMap {
                $0.batteryState == .unknown ? nil : batterySymbol(level: $0.batteryLevel, charging: $0.batteryState == .charging)
            }
            return Self(id: ObjectIdentifier(controller), name: controller.vendorName ?? controller.productCategory,
                        symbol: symbol(for: controller.productCategory), battery: battery)
        }
    }

    static func symbol(for category: String) -> String {
        switch category {
        case GCProductCategoryXboxOne: "logo.xbox"
        case GCProductCategoryDualSense, GCProductCategoryDualShock4: "logo.playstation"
        default: "gamecontroller.fill"
        }
    }

    static func batterySymbol(level: Float, charging: Bool) -> String {
        charging ? "battery.100percent.bolt" : "battery.\(Int((level * 4).rounded()) * 25)percent"
    }
}

/// The controllers playing, in place of on-screen controls the phone no longer needs.
struct ConnectedControllersView: View {
    /// Bumped as controllers come and go.
    @State private var changes = 0

    var body: some View {
        // Batteries report no changes, so they are read again now and then.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let _ = changes
            VStack(alignment: .leading, spacing: 20) {
                ForEach(ConnectedController.list(GCController.controllers())) { controller in
                    HStack(spacing: 14) {
                        Image(systemName: controller.symbol).font(.title).frame(width: 44)
                        Text(controller.name).font(.title3)
                        if let battery = controller.battery { Image(systemName: battery).foregroundStyle(.secondary) }
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in changes += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in changes += 1 }
    }
}

/// The conversation's noodlets, which the controller's View button shows over a game on the TV
/// to switch to another or close the game, without touching the phone.
struct NoodletMenu {
    enum Item: Equatable { case noodlet(LinkAttachment), closeGame }
    enum Action: Equatable { case move(Int), resume, open(LinkAttachment), closeGame }

    var choices: [LinkAttachment] = []
    var current: UUID?
    /// Opened from Play, whose stack of cards it shows.
    var fromPlay = false
    var open: (LinkAttachment) -> Void = { _ in }

    var items: [Item] { choices.map(Item.noodlet) + [.closeGame] }

    /// The game playing, where the menu opens.
    var start: Int { choices.firstIndex { $0.id == current } ?? 0 }

    func respond(to input: HardwareGamepad.MenuInput, at index: Int) -> Action {
        switch input {
        case .left: return .move(max(index - 1, 0))
        case .right: return .move(min(index + 1, items.count - 1))
        case .up, .down: return .move(index)
        case .back: return .resume
        case .choose:
            switch items[index] {
            case .noodlet(let attachment): return attachment.id == current ? .resume : .open(attachment)
            case .closeGame: return .closeGame
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var noodletMenu = NoodletMenu()
    /// Closes a noodlet opened somewhere other than a conversation, in place of dismissing its screen.
    @Entry var closeNoodlet: (() -> Void)?
}

/// The menu over the game on the TV: a row of cards, the chosen one raised.
struct NoodletMenuView: View {
    let menu: NoodletMenu
    let selected: Int

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 28) {
                        ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                            card(item, chosen: index == selected).id(index)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 40)
                }
                .onChange(of: selected, initial: true) { withAnimation { proxy.scrollTo(selected, anchor: .center) } }
            }
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func card(_ item: NoodletMenu.Item, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.12))
                switch item {
                case .noodlet(let attachment):
                    if let data = attachment.card?.image, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: attachment.liveSymbol).font(.system(size: 48))
                    }
                case .closeGame:
                    Image(systemName: "xmark").font(.system(size: 48))
                }
            }
            .frame(width: 300, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white, lineWidth: chosen ? 4 : 0))
            Text(title(item)).font(.title3.weight(chosen ? .semibold : .regular)).lineLimit(1)
        }
        .frame(width: 300)
        .scaleEffect(chosen ? 1.08 : 1)
        .opacity(chosen ? 1 : 0.7)
        .animation(.easeOut(duration: 0.15), value: chosen)
    }

    private func title(_ item: NoodletMenu.Item) -> String {
        switch item {
        case .noodlet(let attachment): attachment.liveTitle
        case .closeGame: "Close Game"
        }
    }
}

/// The menu a noodlet opens from the controller's View button, on the TV while the noodlet plays
/// there and on the phone otherwise; while it is open the controller steers it instead of the noodlet.
@MainActor @Observable final class GameMenu {
    /// The card chosen while the menu is open, or nil while closed.
    private(set) var selected: Int?

    /// Answers the View button of the controller `hardware` follows.
    func follow(hardware: HardwareGamepad, menu: @escaping () -> NoodletMenu, close: @escaping () -> Void) {
        hardware.onView = { [weak self, weak hardware] in
            guard let self, let hardware else { return }
            if self.selected == nil {
                self.selected = menu().start
                hardware.menu = { [weak self] input in self?.respond(to: input, menu: menu(), hardware: hardware, close: close) }
            } else {
                self.dismiss(hardware)
            }
        }
    }

    private func respond(to input: HardwareGamepad.MenuInput, menu: NoodletMenu, hardware: HardwareGamepad, close: () -> Void) {
        guard let selected else { return }
        switch menu.respond(to: input, at: selected) {
        case .move(let index): self.selected = index
        case .resume: dismiss(hardware)
        case .open(let attachment): dismiss(hardware); menu.open(attachment)
        case .closeGame: dismiss(hardware); close()
        }
    }

    private func dismiss(_ hardware: HardwareGamepad) {
        selected = nil
        hardware.menu = nil
    }
}

/// The menu over the game on the TV. It watches the menu itself, since the TV's content is not
/// built again for every change on the phone.
struct GameMenuOverlay: View {
    let gameMenu: GameMenu
    let menu: NoodletMenu

    var body: some View {
        if let selected = gameMenu.selected {
            if menu.fromPlay { ConsoleMenuView(menu: menu, selected: selected) } else { NoodletMenuView(menu: menu, selected: selected) }
        }
    }
}

/// The controllers in hand as Gamepad API pads, lent to a game on the TV: WebKit gives a page
/// controllers only while it is the first responder, which a page in the TV's window, never the
/// key one, cannot be.
enum LentGamepads {
    struct Pad: Codable, Equatable {
        var id: String
        /// In the standard layout: A, B, X, Y, bumpers, triggers, View, Menu, stick presses, d-pad, home.
        var buttons: [Float]
        /// Each stick across and then down.
        var axes: [Float]
    }

    /// One pad for each game controller; while the game is not `playing`, as with Noodle's menu
    /// open over it, they stay but are let go.
    static func pads(_ controllers: [GCController], playing: Bool) -> [Pad] {
        controllers.compactMap { controller in
            guard let full = controller.extendedGamepad else { return nil }
            // View opens Noodle's menu and the system takes home, so the game sees neither.
            let buttons = [full.buttonA, full.buttonB, full.buttonX, full.buttonY, full.leftShoulder, full.rightShoulder,
                           full.leftTrigger, full.rightTrigger, nil, full.buttonMenu, full.leftThumbstickButton,
                           full.rightThumbstickButton, full.dpad.up, full.dpad.down, full.dpad.left, full.dpad.right, nil]
            let axes = [full.leftThumbstick.xAxis.value, -full.leftThumbstick.yAxis.value,
                        full.rightThumbstick.xAxis.value, -full.rightThumbstick.yAxis.value]
            return Pad(id: controller.vendorName ?? controller.productCategory,
                       buttons: buttons.map { playing ? $0?.value ?? 0 : 0 }, axes: playing ? axes : [0, 0, 0, 0])
        }
    }

    /// Gives the page `pads` in place of WebKit's, or nil to give it WebKit's back.
    static func script(_ pads: [Pad]?) -> String {
        let json = pads.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return "window.__noodleLendPads && window.__noodleLendPads(\(json)); 0"
    }
}

/// Lends a game on the TV the controllers in hand, reading them every frame and telling the page
/// only what changed.
@MainActor final class GamepadLender: NSObject {
    private var web: WKWebView?
    private var playing: () -> Bool = { true }
    private var link: CADisplayLink?
    private var lent: [LentGamepads.Pad]?

    func lend(to web: WKWebView, playing: @escaping () -> Bool) {
        self.web = web
        self.playing = playing
        guard link == nil else { return }
        link = CADisplayLink(target: self, selector: #selector(read))
        link?.add(to: .main, forMode: .common)
    }

    /// Gives the page WebKit's controllers back.
    func stop() {
        link?.invalidate()
        link = nil
        if lent != nil { web?.evaluateJavaScript(LentGamepads.script(nil)) }
        lent = nil
        web = nil
    }

    @objc private func read() {
        let pads = LentGamepads.pads(GCController.controllers(), playing: playing())
        guard pads != lent else { return }
        lent = pads
        web?.evaluateJavaScript(LentGamepads.script(pads))
    }
}
