import AppKit
import SwiftUI
import NoodleCore

// Only artwork is a stand-in; the picker and destructive buttons are production views.
struct BotAvatar: View {
    let agent: AgentRecord
    let size: CGFloat
    var body: some View { Circle().fill(.blue).frame(width: size, height: size) }
}

private struct ButtonFixture: View {
    @State private var confirming = false
    @State private var confirmed = 0
    @State private var selected: Set<UUID> = []
    private let agents = [AgentRecord(displayName: "Ruby"), AgentRecord(displayName: "Mara")]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Native destructive buttons").font(.headline)
            DestructiveActionButton(title: "Delete Bot") { confirming = true }
            DestructiveActionButton(title: "Delete Group") { confirming = true }
            DestructiveActionButton(title: "Disabled") {}.disabled(true)
            Text("Confirmed: \(confirmed)").font(.caption)
            GroupMemberPicker(agents: agents, selectedIDs: $selected)
        }.padding(24).frame(width: 420)
            .confirmationDialog("Delete Test Item?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { confirmed += 1 }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This fixture does not delete any data.") }
    }
}

@main private enum DestructiveButtonChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentViewController: NSHostingController(rootView: ButtonFixture().preferredColorScheme(.dark)))
        window.title = "Destructive Button Tests"
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        if !CommandLine.arguments.contains("--open") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                @MainActor func buttons(_ view: NSView) -> [NSButton] {
                    if let button = view as? NSButton { return [button] }
                    return view.subviews.flatMap { buttons($0) }
                }
                let controls = buttons(window.contentView!).filter(\.hasDestructiveAction)
                precondition(controls.map(\.title) == ["Delete Bot", "Delete Group", "Disabled"])
                precondition(controls.allSatisfy { $0.hasDestructiveAction && $0.keyEquivalent.isEmpty })
                precondition(controls[0].isEnabled && !controls[2].isEnabled)
                if #available(macOS 26.0, *) {
                    precondition(controls.allSatisfy {
                        $0.bezelColor == .systemRed && $0.tintProminence == .secondary && $0.borderShape == .capsule
                    })
                }
                var activations = 0
                let coordinator = DestructiveActionButton.Coordinator { activations += 1 }
                let probe = NSButton(title: "Test", target: coordinator, action: #selector(DestructiveActionButton.Coordinator.activate))
                probe.performClick(nil)
                precondition(activations == 1)
                coordinator.action = { activations += 10 }
                probe.performClick(nil)
                precondition(activations == 11)
                print("Native destructive buttons passed: red secondary tint, capsule, labels, disabled state and current action")
                exit(0)
            }
        }
        app.run()
    }
}
