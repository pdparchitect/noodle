import Foundation
import HubLink
import Observation
import SwiftTUIArguments
import SwiftTUICLI
import TerminalCore

@main
struct NoodleTerminalApp: App, SwiftTUICommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "noodle", abstract: "Chat with the bots and groups on your Noodle Hub.")

    @OptionGroup var swiftTUIOptions: SwiftTUIOptions

    var body: some Scene {
        WindowGroup("Noodle") { RootView() }
    }

    /// Runs in the terminal only. SwiftTUI's batteries-included entry point also starts its web host, which serves
    /// the running app on a port to whoever has its URL, with everything the person's Hub lets them do: on loopback
    /// by default, where any process of this user can ask for the URL, and on every interface with `--web --bind`.
    /// This app does not link that host, so neither can start, whatever the flags or environment say.
    static func main() async {
        let app: Self
        do { app = try parse() } catch { exit(withError: error) }
        do {
            try await TerminalRunner.run(app, configuration: app.terminalConfiguration())
        } catch {
            exit(withError: error)
        }
    }

    /// The options and environment as SwiftTUI reads them, with its browser companion and web serving off too.
    func terminalConfiguration(environment: [String: String] = ProcessInfo.processInfo.environment) -> RuntimeConfiguration {
        var configuration = swiftTUIOptions.runtimeConfiguration(environment: environment, isStdoutTTY: isatty(STDOUT_FILENO) != 0)
        configuration.companion = .off
        configuration.web = nil
        configuration.printCompanionURL = false
        return configuration
    }
}

/// Holds the Hubs for as long as the app runs.
struct RootView: View {
    @State private var hubs = TerminalHubs(directory: Self.directory, deviceName: TerminalHubs.standardDeviceName)

    /// Where the Hubs are kept. A development build can be pointed at another folder, so trying it never touches the
    /// person's own pairing.
    private static var directory: URL {
        #if NOODLE_DEV_HOOKS
        if let folder = ProcessInfo.processInfo.environment["NOODLE_TERMINAL_HUBS"] { return URL(fileURLWithPath: folder, isDirectory: true) }
        #endif
        return TerminalHubs.standardDirectory
    }
    @State private var app = AppState()

    var body: some View {
        HomeView(hubs: hubs, app: app)
            .textFieldStyle(FieldStyle())
            .openLinkAction(Markdown.open)
            .task { await hubs.run() }
    }
}

/// A screen pushed over the list, which Escape takes away again.
enum Route: Hashable, Sendable {
    case join, hubs, archived
    case pairDevice(ObjectIdentifier), users(ObjectIdentifier), user(ObjectIdentifier, UUID)
    case newBot, editBot(TerminalHubs.Row.Key), newGroup, editGroup(TerminalHubs.Row.Key)
    case tools(TerminalHubs.Row.Key, HubChats.Tool), sharing(TerminalHubs.Row.Key)
}

/// A question asked before something that cannot be taken back.
struct Confirmation {
    var title: String
    var message: String
    var button: String
    var action: @MainActor () async throws -> Void
}

/// What every screen shares: where the person is, what is asked of them, and what went wrong last.
@MainActor @Observable final class AppState {
    var path: [Route] = []
    var confirming: Confirmation?
    /// One line at the bottom, such as why the Hub refused something or where a file was saved.
    var notice: String?
    var noticeIsProblem = false
    var showsPalette = false
    @ObservationIgnored private var conversations: [TerminalHubs.Row.Key: ConversationState] = [:]
    @ObservationIgnored private var clearing: Task<Void, Never>?

    /// What is typed, attached and chosen in a conversation, kept while the person looks at another.
    func conversation(_ key: TerminalHubs.Row.Key) -> ConversationState {
        if let kept = conversations[key] { return kept }
        let made = ConversationState()
        conversations[key] = made
        return made
    }

    func tell(_ text: String, problem: Bool = false) {
        notice = text
        noticeIsProblem = problem
        clearing?.cancel()
        clearing = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Asks the Hub for something, saying what went wrong if it did.
    func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { tell(error.localizedDescription, problem: true) }
        }
    }

    func push(_ route: Route) { path.append(route) }

    func pop() { if !path.isEmpty { path.removeLast() } }
}

@MainActor @Observable final class ConversationState {
    var draft = ""
    var files: [URL] = []
    var attaching = false
    /// The message chosen for the palette to act on.
    var message: UUID?
    /// Where the messages were scrolled to, so coming back shows the same place.
    var offset = ScrollCellOffset.zero
    /// Whether the newest message stays in view as more come: until the person scrolls back, and again once they
    /// go to the end or send something.
    var followsNewest = true
}

/// The list of bots and groups beside the conversation chosen, as on an iPad; the invitation to join a Hub
/// until there is one.
struct HomeView: View {
    let hubs: TerminalHubs
    let app: AppState

    var body: some View {
        if hubs.memberships.hubs.isEmpty {
            JoinView(hubs: hubs, canCancel: false, done: {})
                .id("join")
        } else {
            // Read here, not only in the binding, so a screen pushed from a button is drawn at once.
            let path = app.path
            VStack(spacing: 0) {
                NavigationStack(path: Binding(get: { path }, set: { app.path = $0 })) {
                    SplitView(hubs: hubs, app: app)
                        .navigationDestination(for: Route.self) { route in
                            Screen(route: route, hubs: hubs, app: app)
                        }
                }
                if let notice = app.notice {
                    if app.noticeIsProblem { Text(notice).foregroundStyle(.red).lineLimit(2) } else { Text(notice).lineLimit(2) }
                }
            }
            .alert(app.confirming?.title ?? "", isPresented: Binding(get: { app.confirming != nil }, set: { if !$0 { app.confirming = nil } }),
                   actions: {
                       if let confirming = app.confirming {
                           Button(confirming.button, role: .destructive) { app.run(confirming.action) }
                       }
                       Button("Cancel", role: .cancel) {}
                   }, message: { Text(app.confirming?.message ?? "") })
            .id("home")
        }
    }
}

/// Pairs this terminal with a Hub from an invitation, as a new phone does.
struct JoinView: View {
    let hubs: TerminalHubs
    let canCancel: Bool
    let done: @MainActor @Sendable () -> Void
    @State private var invitation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Join a Noodle Hub").bold()
            Text("On a device already paired with the Hub, invite a new device, then paste the invitation link or code here.")
                .foregroundStyle(.secondary)
            TextField("Invitation link or code", text: $invitation)
                .onSubmit { join() }
            HStack(spacing: 2) {
                Button(hubs.memberships.isJoining ? "Joining…" : "Join") { join() }
                    .disabled(hubs.memberships.isJoining || invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if canCancel {
                    Button("Cancel") { done() }
                }
            }
            if let error = hubs.memberships.joinError {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: 72, maxHeight: .infinity, alignment: .topLeading)
    }

    private func join() {
        let text = invitation
        guard !hubs.memberships.isJoining, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            await hubs.join(text)
            if hubs.memberships.joinError == nil {
                invitation = ""
                done()
            }
        }
    }
}

/// A text field whose border stays quiet until it has the keys: grey and thin, then heavy in the accent colour.
struct FieldStyle: TextFieldStyle {
    @MainActor func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        HStack(spacing: 0) {
            configuration.fieldContent
                .foregroundStyle(configuration.isShowingPrompt ? configuration.placeholderStyle : configuration.chrome.foregroundStyle)
            Spacer(minLength: 0)
        }
        .padding(.init(horizontal: 1, vertical: 1))
        .overlay {
            if configuration.focusActive {
                Rectangle().strokeBorder(.tint, style: .heavy)
            } else {
                Rectangle().strokeBorder(.secondary)
            }
        }
    }
}

extension View {
    /// A box's outline: grey and thin, then heavy in the accent colour while the box has the keys.
    /// `filling` stretches it to the bottom of the space it is given.
    func box(focused: Bool, filling: Bool = false) -> some View {
        frame(maxHeight: filling ? .infinity : nil, alignment: .top)
            .padding(.init(horizontal: 1, vertical: 1))
            .overlay {
                if focused {
                    Rectangle().strokeBorder(.tint, style: .heavy)
                } else {
                    Rectangle().strokeBorder(.secondary)
                }
            }
    }
}

/// A command the palette offers, made from data so the palette always fits what is chosen.
struct PaletteEntry: Identifiable {
    let id: String
    let name: String
    var description: String? = nil
    let action: @MainActor @Sendable () -> Void

    init(_ name: String, _ description: String? = nil, action: @escaping @MainActor @Sendable () -> Void) {
        id = name
        self.name = name
        self.description = description
        self.action = action
    }
}

/// The commands for what is chosen, narrowed as the person types: Up and Down choose one, Return runs it, Escape
/// closes the palette.
struct CommandPalette: View {
    let entries: [PaletteEntry]
    let close: @MainActor () -> Void
    @State private var filter = ""
    @State private var index = 0
    @FocusState private var focused: Bool?
    private static let shownRows = 14

    private var shown: [PaletteEntry] {
        let words = filter.lowercased().split(separator: " ")
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = (entry.name + " " + (entry.description ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let shown = shown, chosen = min(index, max(0, shown.count - 1))
        let first = max(0, min(chosen - Self.shownRows / 2, shown.count - Self.shownRows))
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type to find a command", text: $filter)
                .focused($focused, equals: true)
                .onSubmit { run(shown, chosen) }
                .onKeyPress(.arrowDown) { _ in
                    index = min(chosen + 1, max(0, shown.count - 1))
                    return .handled
                }
                .onKeyPress(.arrowUp) { _ in
                    index = max(chosen - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) { _ in
                    close()
                    return .handled
                }
            Divider()
            if shown.isEmpty { Text(" No commands match").foregroundStyle(.secondary) }
            ForEach(Array(shown.enumerated().dropFirst(first).prefix(Self.shownRows)), id: \.element.id) { offset, entry in
                HStack(spacing: 1) {
                    if offset == chosen { Text("▶ \(entry.name)").bold().foregroundStyle(.tint) } else { Text("  \(entry.name)") }
                    Spacer()
                    if let description = entry.description { Text(description).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Text("Up and Down choose · Return runs · Escape closes").foregroundStyle(.secondary).padding(.top, 1)
        }
        .padding(.horizontal)
        .border(.secondary)
        .background(.background)
        .frame(maxWidth: 96)
        .padding(.top, 2)
        .onAppear { focused = true }
        .onChange(of: filter) { _, _ in index = 0 }
    }

    private func run(_ shown: [PaletteEntry], _ chosen: Int) {
        guard shown.indices.contains(chosen) else { return }
        close()
        shown[chosen].action()
    }
}
