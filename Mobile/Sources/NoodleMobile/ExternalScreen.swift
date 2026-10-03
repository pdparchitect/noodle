import GameController
import HubLink
import SwiftUI
import UIKit

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

/// The conversation's noodlets, which the controller's home button shows over a game on the TV
/// to switch to another or close the game, without touching the phone.
struct NoodletMenu {
    enum Item: Equatable { case noodlet(LinkAttachment), closeGame }
    enum Action: Equatable { case move(Int), resume, open(LinkAttachment), closeGame }

    var choices: [LinkAttachment] = []
    var current: UUID?
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

/// The menu a game on the TV opens from the controller's home button; while it is open the
/// controller steers it instead of the game.
@MainActor @Observable final class GameMenu {
    /// The card chosen while the menu is open, or nil while closed.
    private(set) var selected: Int?

    /// Takes the home button while the game is on the TV, and gives it back after.
    func follow(onTV: Bool, hardware: HardwareGamepad, menu: @escaping () -> NoodletMenu, close: @escaping () -> Void) {
        guard onTV else {
            selected = nil
            hardware.menu = nil
            hardware.onHome = nil
            return
        }
        hardware.onHome = { [weak self, weak hardware] in
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
