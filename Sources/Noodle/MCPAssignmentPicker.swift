import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

struct MCPAssignmentPicker: View {
    let controller: MCPController
    @Binding var selectedIDs: Set<UUID>
    /// Noodle's own tools sit in the same list; each carries its own scope.
    let calendars: EventKitController
    let reminders: EventKitController
    @Binding var calendarIDs: Set<String>
    @Binding var reminderIDs: Set<String>
    /// A built-in tool stays in the list while it is on, even before anything is chosen,
    /// so this lives in the sheet: switching tabs rebuilds this view.
    @Binding var builtIn: Set<EventKitAssignments.Kind>
    @State private var showingAdd = false
    @State private var search = ""
    @State private var wantsNewTool = false
    @State private var showingNewTool = false
    @State private var editing: MCPConnectionRecord?
    @State private var removing: MCPConnectionRecord?
    /// Room for five tools, so the sheet does not jump as they are added or removed.
    private static let listHeight: CGFloat = 5 * 44

    /// On because it is switched on, or because it already has something chosen.
    private var shownBuiltIn: [EventKitAssignments.Kind] {
        EventKitAssignments.Kind.allCases.filter {
            builtIn.contains($0) || !($0 == .calendar ? calendarIDs : reminderIDs).isEmpty
        }
    }
    private var missingBuiltIn: [EventKitAssignments.Kind] {
        EventKitAssignments.Kind.allCases.filter { !shownBuiltIn.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Button { search = ""; showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                        MCPConnectionChooser(controller: controller, selectedIDs: $selectedIDs, search: $search,
                            builtIn: $builtIn, missingBuiltIn: missingBuiltIn,
                            onNewTool: { wantsNewTool = true; showingAdd = false }, onDone: { showingAdd = false })
                            .onDisappear {
                                // Wait for the popover to close before presenting a sheet
                                // on the bot editor. No nested popover or global window.
                                if wantsNewTool { wantsNewTool = false; showingNewTool = true }
                            }
                    }
            }
            if selectedIDs.isEmpty && shownBuiltIn.isEmpty {
                Button { search = ""; showingAdd = true } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle)
                        Text("Add tools to this bot")
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: Self.listHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Add tools to this bot")
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(controller.registry.connections.filter { selectedIDs.contains($0.id) }) { connection in
                            HStack(spacing: 10) {
                                MCPConnectionIcon(connection: connection, size: 26)
                                Text(connection.name).lineLimit(1)
                                MCPConnectionMaturityBadge(connection: connection)
                                Spacer()
                                Button { editing = connection } label: {
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Edit \(connection.name)")
                                Button { removing = connection } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Remove \(connection.name) from this bot")
                            }.padding(8)
                        }
                        ForEach(shownBuiltIn, id: \.self) { kind in
                            EventKitToolRow(controller: kind == .calendar ? calendars : reminders,
                                            selectedIDs: kind == .calendar ? $calendarIDs : $reminderIDs,
                                            onRemove: {
                                                builtIn.remove(kind)
                                                if kind == .calendar { calendarIDs = [] } else { reminderIDs = [] }
                                            })
                        }
                    }
                }.frame(height: Self.listHeight)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .sheet(isPresented: $showingNewTool) {
            ToolCreationSheet(controller: controller, onAdded: { selectedIDs.insert($0) }).noodleSheetSizing()
        }
        .sheet(item: $editing) { connection in
            MCPEditor(controller: controller, existing: connection).noodleSheetSizing()
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { connection in
            Button("Remove Tool", role: .destructive) { selectedIDs.remove(connection.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This bot loses access to it when you save. The tool connection itself is not deleted.")
        }
    }
}

struct MCPConnectionChooser: View {
    let controller: MCPController
    @Binding var selectedIDs: Set<UUID>
    @Binding var search: String
    var builtIn: Binding<Set<EventKitAssignments.Kind>>? = nil
    var missingBuiltIn: [EventKitAssignments.Kind] = []
    let onNewTool: () -> Void
    let onDone: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            TextField("Search connections", text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            ScrollView {
                LazyVStack(spacing: 4) {
                    if let builtIn {
                        ForEach(missingBuiltIn.filter {
                            search.isEmpty || $0.toolName.localizedCaseInsensitiveContains(search)
                        }, id: \.self) { kind in
                            Button { builtIn.wrappedValue.insert(kind) } label: {
                                HStack(spacing: 10) {
                                    EventKitToolIcon(symbol: kind == .calendar ? "calendar" : "checklist", size: 28)
                                    VStack(alignment: .leading) {
                                        Text(kind.toolName).foregroundStyle(.primary)
                                        Text("\(kind.noun.capitalized)s on this Mac, chosen per bot")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    ForEach(controller.registry.connections.filter {
                        !selectedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                    }) { connection in
                        Button { selectedIDs.insert(connection.id) } label: {
                            HStack(spacing: 10) {
                                MCPConnectionIcon(connection: connection, size: 28)
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(connection.name).foregroundStyle(.primary)
                                        MCPConnectionMaturityBadge(connection: connection)
                                    }
                                    Text(connection.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if controller.registry.connections.isEmpty {
                        Text("No saved connections. Choose New Tool to add one.").foregroundStyle(.secondary).padding()
                    }
                }
            }
            HStack {
                Button("New Tool…", action: onNewTool)
                Spacer()
                Button("Done", action: onDone)
            }
        }.padding(16).frame(width: 330, height: 260)
    }
}
