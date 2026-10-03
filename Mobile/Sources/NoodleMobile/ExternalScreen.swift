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
