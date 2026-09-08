// Run with Sources/Noodle/SheetSizing.swift; this fixture never opens Noodle's store.
import AppKit
import SwiftUI
import NoodleCore

@MainActor
private final class SheetFixture: ObservableObject {
    @Published var presented = true
    @Published var contentHeight: CGFloat = 280
    @Published var showMembers = false
    @Published var selectedIDs = Set<UUID>()
    let agents = (1...40).map { AgentRecord(displayName: "Bot \($0)") }
    weak var header: NSView?
    weak var footer: NSView?
}

private struct PositionProbe: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        capture(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Only the artwork is a stand-in; the member picker and sheet sizing are the
// production views. No runtime, model provider or persistent store is loaded.
struct BotAvatar: View {
    let agent: AgentRecord
    let size: CGFloat
    var body: some View { Circle().fill(.blue).frame(width: size, height: size) }
}

private struct FixtureRoot: View {
    @ObservedObject var fixture: SheetFixture

    var body: some View {
        Color.clear.frame(width: 800, height: 850)
            .sheet(isPresented: $fixture.presented) {
                VStack(spacing: 0) {
                    Text("Group Info").padding(16)
                        .background(PositionProbe { fixture.header = $0 })
                    Divider()
                    if fixture.showMembers {
                        GroupMemberPicker(agents: fixture.agents, selectedIDs: $fixture.selectedIDs)
                            .padding(20)
                    } else {
                        Color.gray.frame(height: fixture.contentHeight).padding(20)
                    }
                    Text("Footer").padding(16)
                        .background(PositionProbe { fixture.footer = $0 })
                }
                .frame(width: 460)
                .noodleSheetSizing()
            }
    }
}

@main
private enum SheetSizingTest {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let fixture = SheetFixture()
        let window = NSWindow(contentViewController: NSHostingController(rootView: FixtureRoot(fixture: fixture)))
        window.title = "Noodle sheet sizing regression test"
        window.center()
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let sheet = window.sheets.first else { throw Failure("Sheet was not presented") }
                let initial = sheet.frame.size
                for height: CGFloat in [360, 140, 360, 140, 280] {
                    fixture.contentHeight = height
                    try await Task.sleep(for: .seconds(1))
                    let actual = sheet.frame.size
                    let expectedHeight = initial.height + height - 280
                    print("content=\(height) sheet=\(actual) expectedHeight=\(expectedHeight)")
                    guard abs(actual.height - expectedHeight) < 2,
                          abs(actual.width - initial.width) < 2 else {
                        throw Failure("Sheet did not track its content size")
                    }
                    try checkControls(fixture, in: sheet)
                }
                fixture.selectedIDs = Set(fixture.agents.prefix(11).map(\.id))
                fixture.showMembers = true
                try await Task.sleep(for: .seconds(1))
                let groupHeight = sheet.frame.height
                try checkControls(fixture, in: sheet)
                fixture.selectedIDs = Set(fixture.agents.prefix(1).map(\.id))
                try await Task.sleep(for: .seconds(1))
                let singleHeight = sheet.frame.height
                try checkControls(fixture, in: sheet)
                guard singleHeight < groupHeight - 50 else { throw Failure("Removing members did not shrink the group sheet") }
                fixture.selectedIDs = Set(fixture.agents.prefix(11).map(\.id))
                try await Task.sleep(for: .seconds(1))
                guard abs(sheet.frame.height - groupHeight) < 2 else { throw Failure("Adding members did not restore the group sheet height") }
                try checkControls(fixture, in: sheet)
                print("Group picker: 11 members=\(groupHeight), 1 member=\(singleHeight), restored=\(sheet.frame.height)")
                fixture.selectedIDs = Set(fixture.agents.map(\.id))
                try await Task.sleep(for: .seconds(1))
                guard sheet.frame.height <= groupHeight + 20 else { throw Failure("Large membership grid did not remain scrollable and bounded") }
                try checkControls(fixture, in: sheet)
                fixture.selectedIDs = []
                try await Task.sleep(for: .seconds(1))
                guard abs(sheet.frame.height - singleHeight) < 2 else { throw Failure("Empty group did not return to compact height") }
                try checkControls(fixture, in: sheet)
                print("Sheet sizing regression passed")
                window.orderOut(nil)
                exit(0)
            } catch {
                fputs("\(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    private static func checkControls(_ fixture: SheetFixture, in sheet: NSWindow) throws {
        guard let header = fixture.header, let footer = fixture.footer,
              let content = sheet.contentView else { throw Failure("Missing control position probes") }
        let bounds = content.convert(content.bounds, to: nil)
        let headerBounds = header.convert(header.bounds, to: nil)
        let footerBounds = footer.convert(footer.bounds, to: nil)
        guard abs(headerBounds.maxY - bounds.maxY) < 2,
              headerBounds.minY >= bounds.minY,
              abs(footerBounds.minY - bounds.minY) < 2,
              footerBounds.maxY <= bounds.maxY else {
            throw Failure("Header/footer were clipped or left a gap: \(bounds), \(headerBounds), \(footerBounds)")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
