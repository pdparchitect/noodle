import AppKit
import NoodleCore
import NoodleMCP
import NoodleRuntime
import SwiftUI

/// One window per tool connection, showing its page, for an app whose main window has no place for it.
@MainActor
final class ToolWindows: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSWindow] = [:]

    func show(_ connection: ToolConnection, controller: ToolConnectionsController) {
        if let window = windows[connection.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = connection.name
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 520, height: 420)
        let page = NSHostingController(rootView: ToolPage(controller: controller, connectionID: connection.id)
            .background(.windowBackground))
        // The window keeps the size it is given and the person's resizing, not the page's.
        page.sizingOptions = []
        window.contentViewController = page
        window.setContentSize(NSSize(width: 760, height: 720))
        window.delegate = self
        window.center()
        windows[connection.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Retitles each open window by `names` and closes those whose connection is gone.
    func synchronize(names: [UUID: String]) {
        for (id, window) in windows {
            if let name = names[id] { window.title = name } else { window.close() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

/// A tool connection's page, shown where a conversation would be: where it stands and what it needs, the bots it is
/// assigned to, what its watch for new alerts found, the tools it offers, and its activity since the app started.
/// It draws no background of its own, so it sits on the window's as a conversation does.
public struct ToolPage: View {
    let controller: ToolConnectionsController
    let connectionID: UUID
    /// A bot's picture in the app's own style.
    let picture: (AgentRecord, CGFloat) -> AnyView
    /// The app's list to add bots from, given the bots, those chosen and the search, as its group editor shows it;
    /// without it, a menu of names.
    let chooser: ((_ agents: [AgentRecord], _ chosen: Binding<Set<UUID>>, _ search: Binding<String>) -> AnyView)?
    @State private var editing: ToolConnection?
    @State private var choosing = false
    @State private var search = ""
    @State private var assignmentError: String?
    @State private var tools: ToolList = .loading

    public init(controller: ToolConnectionsController, connectionID: UUID,
                picture: @escaping (AgentRecord, CGFloat) -> AnyView = { AnyView(BotAvatar(agent: $0, size: $1, showsShadow: false)) },
                chooser: ((_ agents: [AgentRecord], _ chosen: Binding<Set<UUID>>, _ search: Binding<String>) -> AnyView)? = nil) {
        self.controller = controller
        self.connectionID = connectionID
        self.picture = picture
        self.chooser = chooser
    }

    fileprivate struct OfferedTool: Equatable {
        let name: String, summary: String, readOnly: Bool
    }

    fileprivate enum ToolList: Equatable {
        case loading, loaded([OfferedTool]), failed(String)
    }

    private var connection: ToolConnection? { controller.registry.connections.first { $0.id == connectionID } }

    public var body: some View {
        if let connection {
            ScrollView { page(connection) }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .task(id: connection.id) { await listTools(connection) }
                .sheet(item: $editing) { ToolConnectionEditor(controller: controller, existing: $0).noodleSheetSizing() }
        }
    }

    private func page(_ connection: ToolConnection) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            header(connection)
            figures(connection)
            assigned(connection)
            if controller.store.watches(connection) { alerts(connection) }
            offered
            ToolActivity(log: controller.activity.log(for: connection.id))
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 40)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private func header(_ connection: ToolConnection) -> some View {
        let status = controller.status(of: connection)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ToolConnectionIcon(connection: connection, size: 60)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 6) {
                    // One line, shrinking a little before it is cut short; the whole name shows on hover.
                    Text(connection.name)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(connection.name)
                    HStack(spacing: 6) {
                        StatusTag(status: status)
                        if controller.store.watches(connection) { PageTag(text: "Watched for alerts", symbol: "dot.radiowaves.left.and.right") }
                    }
                }
                Spacer(minLength: 12)
                actions(connection, status: status)
            }
            if let summary = ToolCatalog.definition(for: connection)?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let reason) = status {
                Label { Text(reason).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
            } else if case .signingIn(let stage) = status, !stage.isEmpty {
                Label(stage, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func actions(_ connection: ToolConnection, status: ToolConnectionStatus) -> some View {
        if status != .managed {
            HStack(spacing: 8) {
                if case .signingIn = status {
                    Button("Cancel") { controller.cancelSignIn() }
                } else {
                    switch controller.signInAction(for: connection) {
                    case .edit(let title):
                        primary(title, needed: status.needsAttention) { editing = connection }
                    case .connect(let title):
                        primary(title, needed: status.needsAttention) { controller.connect(connection) }
                    case nil:
                        EmptyView()
                    }
                }
                Menu {
                    Button("Edit…") { editing = connection }
                    if controller.offersSignOut(connection) {
                        Divider()
                        Button("Sign Out", role: .destructive) { controller.signOut(connection) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                // A plain mark rather than a capsule: a menu's capsule does not take the large size of the button
                // beside it, so the two never stood the same height.
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder private func primary(_ title: String, needed: Bool, action: @escaping () -> Void) -> some View {
        if needed {
            Button(title, action: action).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(controller.isSigningIn)
        } else {
            Button(title, action: action).disabled(controller.isSigningIn)
        }
    }

    // MARK: Figures

    private func figures(_ connection: ToolConnection) -> some View {
        let watch = controller.store.watchStatus[connection.id]
        var cells: [(value: String, label: String)] = [("\(controller.holders(of: connection).count)", "Assigned")]
        if controller.store.watches(connection) {
            cells.append((watch.map { "\($0.checks)" } ?? "–", "Checks"))
            cells.append((watch.map { "\($0.wakes.count)" } ?? "0", "Wakes"))
            cells.append((watch.map { Self.time($0.nextCheck) } ?? "–", "Next check"))
        } else if case .loaded(let list) = tools {
            cells.append(("\(list.count)", "Tools"))
        }
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 { Divider().frame(height: 30) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1)
                    Text(cell.label).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 12)
        .card()
    }

    // MARK: Assigned to

    private func assigned(_ connection: ToolConnection) -> some View {
        let holders = controller.holders(of: connection)
        let others = controller.agents.filter { agent in !holders.contains { $0.id == agent.id } }
        return VStack(alignment: .leading, spacing: 10) {
            PageHeading(title: "Assigned To", count: holders.isEmpty ? nil : holders.count)
            ToolFlow(spacing: 8) {
                ForEach(holders, id: \.id) { agent in
                    AgentChip(name: agent.displayName, picture: picture(agent, 20)) { setAssigned(false, connection, agent) }
                }
                if !others.isEmpty {
                    addControl(connection, holders: holders, others: others)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
            }
            if holders.isEmpty {
                Text("No agent can use it until it is assigned.").font(.callout).foregroundStyle(.secondary)
            }
            if let assignmentError {
                Text(assignmentError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func addControl(_ connection: ToolConnection, holders: [AgentRecord], others: [AgentRecord]) -> some View {
        let title = holders.isEmpty ? "Assign" : "Add"
        if let chooser {
            Button { search = ""; choosing = true } label: { Label(title, systemImage: "plus").font(.callout) }
                .buttonStyle(.borderless)
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    // Choosing a bot assigns it; one already assigned is not offered.
                    chooser(controller.agents.filter { $0.archivedAt == nil }, Binding(
                        get: { Set(controller.holders(of: connection).map(\.id)) },
                        set: { chosen in
                            for agent in controller.agents where chosen.contains(agent.id) && !controller.holders(of: connection).contains(where: { $0.id == agent.id }) {
                                setAssigned(true, connection, agent)
                            }
                        }), $search)
                }
        } else {
            Menu {
                ForEach(others, id: \.id) { agent in
                    Button(agent.displayName) { setAssigned(true, connection, agent) }
                }
            } label: {
                Label(title, systemImage: "plus").font(.callout)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
        }
    }

    private func setAssigned(_ assigned: Bool, _ connection: ToolConnection, _ agent: AgentRecord) {
        do {
            try controller.setAssigned(assigned, connection, to: agent)
            assignmentError = nil
        } catch { assignmentError = error.localizedDescription }
    }

    // MARK: Alerts

    private func alerts(_ connection: ToolConnection) -> some View {
        let watch = controller.store.watchStatus[connection.id]
        return VStack(alignment: .leading, spacing: 10) {
            PageHeading(title: "Alerts")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    WatchLight(state: watch.map { $0.last.isFailure ? .failing : .watching } ?? .idle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(watch.map { Self.result($0.last) } ?? notCheckedReason(connection))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(watch?.last.isFailure == true ? Color.red : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let watch {
                            Text("Last checked \(Self.time(watch.lastChecked)) · next \(Self.time(watch.nextCheck))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                if let wakes = watch?.wakes, !wakes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        let shown = Array(wakes.reversed().prefix(8))
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, wake in
                            TimelineRow(time: Self.time(wake.date), symbol: "bell.fill", title: "Found \(wake.found)",
                                        last: index == shown.count - 1) {
                                if !wake.woke.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(wake.woke, id: \.self) { name in
                                            let agent = controller.agents.first { $0.displayName == name }
                                            HStack(spacing: 4) {
                                                if let agent { picture(agent, 14) }
                                                Text(name).font(.caption)
                                            }
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .card()
        }
    }

    private func notCheckedReason(_ connection: ToolConnection) -> String {
        if controller.holders(of: connection).isEmpty { return "Not checked until it is assigned" }
        if !controller.isConnected(connection) || controller.errors[connection.id] != nil { return "Not checked until it works" }
        return "Waiting for the first check"
    }

    private static func result(_ checked: AlertWatcher.Checked) -> String {
        switch checked {
        case .started: "Watching for new alerts from now on"
        case .nothingNew: "Nothing new"
        case .found(let what): "Found \(what)"
        case .failed(let reason): "Could not check: \(reason)"
        }
    }

    /// The time alone within a day either side of now, which leaves no doubt which day it is; the date too beyond.
    fileprivate static func time(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) < 86_400 ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    // MARK: Tools offered

    private var offered: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .loaded(let list) = tools {
                PageHeading(title: "Tools", count: list.isEmpty ? nil : list.count)
            } else {
                PageHeading(title: "Tools")
            }
            switch tools {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Listing its tools").font(.callout).foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .loaded(let list) where list.isEmpty:
                Text("It offers no tools.").font(.callout).foregroundStyle(.secondary)
            case .loaded(let list):
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { index, tool in
                        if index > 0 { Divider().padding(.leading, 14) }
                        OfferedToolRow(tool: tool)
                    }
                }
                .card()
            }
        }
    }

    /// Lists the tools the connection offers, as bots are offered them, once the page opens.
    private func listTools(_ connection: ToolConnection) async {
        struct Annotations: Decodable { let readOnlyHint: Bool? }
        struct Tool: Decodable { let name: String; let description: String?; let annotations: Annotations? }
        struct Listed: Decodable { let tools: [Tool] }
        do {
            let data = try await controller.service.perform(MCPBridgeRequest(session: "", connectionID: connection.id, action: .tools,
                                                                             tool: nil, arguments: nil), connection: connection)
            tools = .loaded(try JSONDecoder().decode(Listed.self, from: data).tools.map {
                OfferedTool(name: $0.name, summary: $0.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            readOnly: $0.annotations?.readOnlyHint == true)
            })
        } catch {
            tools = .failed("Its tools could not be listed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Parts

private extension AlertWatcher.Checked {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

private extension View {
    /// A soft panel on the window's background, as the case record's rows are.
    func card() -> some View {
        background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct PageHeading: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.headline)
            if let count { Text("\(count)").font(.headline.weight(.regular)).foregroundStyle(.secondary).monospacedDigit() }
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small capsule label.
private struct PageTag: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .background(color == .secondary ? Color.primary.opacity(0.07) : color.opacity(0.15), in: .capsule)
        .fixedSize()
    }
}

/// Where the connection stands, as a tag: colour only for what needs the person.
private struct StatusTag: View {
    let status: ToolConnectionStatus

    var body: some View {
        switch status {
        case .connected: PageTag(text: "Connected", symbol: "checkmark")
        case .managed: PageTag(text: Organisation.managedText, symbol: "building.2")
        case .signingIn: PageTag(text: "Signing in", symbol: "arrow.triangle.2.circlepath")
        case .failed: PageTag(text: "Needs attention", symbol: "exclamationmark.triangle.fill", color: .red)
        case .tokenRequired: PageTag(text: "Token required", symbol: "key.fill", color: .orange)
        case .credentialsRequired: PageTag(text: "Credentials required", symbol: "key.fill", color: .orange)
        case .signInRequired: PageTag(text: "Sign-in required", symbol: "person.crop.circle.badge.exclamationmark", color: .orange)
        }
    }
}

/// A bot the connection is assigned to, as a chip with its picture; the mark that appears on hover takes it away.
private struct AgentChip: View {
    let name: String
    let picture: AnyView
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            picture
            Text(name).font(.callout).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(hovering ? 0.12 : 0), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("Remove")
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(Color.primary.opacity(hovering ? 0.09 : 0.06), in: .capsule)
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove", role: .destructive, action: remove) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A steady light for a watch: on while it is checked, red while checks fail, dim before the first.
private struct WatchLight: View {
    enum State { case watching, failing, idle }
    let state: State

    var body: some View {
        let color: Color = switch state {
        case .watching: .green
        case .failing: .red
        case .idle: .secondary
        }
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.25)).frame(width: 18, height: 18))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

/// A row on a rail, as the case's audit log draws them: the time, a marker joined to the next, a title and what is under it.
private struct TimelineRow<Detail: View>: View {
    let time: String
    let symbol: String
    let title: String
    var last = false
    var emphasis = false
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                // From the card's edge, as every other card's rows start.
                .frame(width: 44, alignment: .leading)
                .padding(.top, 3)
            ZStack(alignment: .top) {
                if !last { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).padding(.top, 20) }
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(emphasis ? Color.red : Color.primary.opacity(0.75))
                    .frame(width: 20, height: 20)
                    .background(emphasis ? Color.red.opacity(0.14) : Color.primary.opacity(0.07), in: Circle())
            }
            .frame(width: 20)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                detail
            }
            .padding(.top, 1)
            .padding(.bottom, last ? 4 : 12)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

/// A tool the connection offers: its name, whether it only reads, and what it does, in full once clicked.
private struct OfferedToolRow: View {
    let tool: ToolPage.OfferedTool
    @State private var expanded = false
    /// The summary's height on one line and in full, so opening it can grow between them.
    @State private var lineHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tool.name).font(.callout.monospaced().weight(.semibold))
                    if tool.readOnly { PageTag(text: "Read-only") }
                    Spacer(minLength: 0)
                    if !tool.summary.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                if !tool.summary.isEmpty {
                    // Both ways laid out at once, one shown, in a frame whose height moves between them, as a
                    // change of line limit would snap rather than grow.
                    ZStack(alignment: .topLeading) {
                        Text(tool.summary)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                            .opacity(expanded ? 1 : 0)
                        Text(tool.summary)
                            .lineLimit(1)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
                            .opacity(expanded ? 0 : 1)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(height: lineHeight == 0 ? nil : (expanded ? fullHeight : lineHeight), alignment: .top)
                    .clipped()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.25), value: expanded)
    }
}

/// The connection's activity since the app started, newest first, on a rail: each run of the same quiet line, such as
/// checks that found nothing, shown as one.
private struct ToolActivity: View {
    let log: ActivityLog
    /// The most lines shown; the rest stay in the log.
    static let shown = 80

    var body: some View {
        // The log is not observable; its revision is read again every second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let entries = Array(ActivityEntry.collapsingRepeats(log.entries).reversed().prefix(Self.shown))
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(title: "Activity")
                if entries.isEmpty {
                    Text("Nothing yet since the app started.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            let kind = Kind(entry.title)
                            TimelineRow(time: ToolPage.time(entry.date), symbol: kind.symbol, title: entry.title,
                                        last: index == entries.count - 1, emphasis: kind == .failure) {
                                let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(6)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .card()
                }
            }
        }
    }

    /// What a line is about, for its marker.
    enum Kind {
        case call, check, found, access, failure, other

        init(_ title: String) {
            let lower = title.lowercased()
            if lower.contains("failed") || lower.hasPrefix("could not") { self = .failure }
            else if lower.contains(" called ") { self = .call }
            else if lower.hasPrefix("found") { self = .found }
            else if lower.contains("alerts") { self = .check }
            else if lower.contains("sign") || lower.contains("token") || lower.contains("credentials") { self = .access }
            else { self = .other }
        }

        var symbol: String {
            switch self {
            case .call: "arrow.up.right"
            case .check: "dot.radiowaves.left.and.right"
            case .found: "bell.fill"
            case .access: "key.fill"
            case .failure: "exclamationmark"
            case .other: "circle.fill"
            }
        }
    }
}

/// Lays chips out in lines, wrapping as needed.
private struct ToolFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
