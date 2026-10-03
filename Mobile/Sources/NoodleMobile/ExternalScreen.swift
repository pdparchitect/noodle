import HubLink
import NoodleBrand
import SwiftUI
import UIKit

/// A TV the phone reaches by Screen Mirroring or a cable. A game opened on the phone plays there
/// while the phone becomes its controller; otherwise it shows the wordmark.
@MainActor @Observable final class ExternalScreen {
    static let shared = ExternalScreen()
    /// Whether a TV is there for Noodle to show on.
    var connected = false
    /// What the TV shows, and which game put it there.
    private(set) var shown: (id: UUID, view: AnyView)?

    /// Whether a game with `controls` plays on the TV, unless the person brought it back to the phone.
    func plays(_ controls: Gamepad?, onPhone: Bool) -> Bool { connected && controls != nil && !onPhone }

    func show(_ id: UUID, @ViewBuilder _ view: () -> some View) { shown = (id, AnyView(view())) }

    /// Takes `id`'s game off the TV, if it is still the one there.
    func clear(_ id: UUID) {
        if shown?.id == id { shown = nil }
    }
}

/// Takes the TV's scene from iOS, which would otherwise mirror the phone there.
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ExternalScreenView(screen: .shared))
        window.isHidden = false
        self.window = window
        ExternalScreen.shared.connected = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        ExternalScreen.shared.connected = false
    }
}

private struct ExternalScreenView: View {
    let screen: ExternalScreen

    var body: some View {
        ZStack {
            Color.black
            if let shown = screen.shown {
                shown.view.id(shown.id)
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width / 4
                    Wordmark(wordWidth: width)
                        .stroke(.white, style: StrokeStyle(lineWidth: Wordmark.lineWidth(forWordWidth: width), lineCap: .round, lineJoin: .round))
                }
            }
        }
        .ignoresSafeArea()
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
    @Binding var onPhone: Bool
    @Binding var connecting: Bool

    var body: some View {
        if onTV {
            let model = UIDevice.current.model
            Button("Show on \(model)", systemImage: model == "iPad" ? "ipad" : "iphone") { onPhone = true }
        } else {
            Button("Show on TV", systemImage: "tv") {
                if ExternalScreen.shared.connected { onPhone = false } else { connecting = true }
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
