import AppKit
import NoodleExternalTools
import SwiftUI

/// Asks the person in a small window of its own, in front of other apps. A question nobody
/// answers within two minutes counts as declined.
@MainActor public final class ExternalPrompter: ExternalPrompting {
    let appName: String
    /// "browser" or "computer".
    let noun: String
    static let timeout: Duration = .seconds(120)

    public init(appName: String, noun: String) { self.appName = appName; self.noun = noun }

    public func approve(_ launcher: ExternalLauncher) async -> Bool {
        await ask(launcher, title: "Allow “\(launcher.name)” to use \(appName)?",
                  message: "It can create \(noun)s and use the ones you lend it.", caution: launcher.caution, items: [],
                  decline: "Don’t Allow", accept: "Allow") != nil
    }

    public func pick(_ launcher: ExternalLauncher, from items: [ExternalItem]) async -> UUID? {
        await ask(launcher, title: "“\(launcher.name)” wants to borrow a \(noun)", message: nil, caution: nil, items: items,
                  decline: "Don’t Lend", accept: "Lend")
    }

    public func confirm(_ launcher: ExternalLauncher, message: String, action: String) async -> Bool {
        await ask(launcher, title: message, message: nil, caution: nil, items: [], decline: "Cancel", accept: action) != nil
    }

    /// Nil when declined; otherwise the picked item, or a placeholder when there was nothing to pick.
    private func ask(_ launcher: ExternalLauncher, title: String, message: String?, caution: String?, items: [ExternalItem],
                     decline: String, accept: String) async -> UUID? {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = appName
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<UUID?, Never>) in
            var finished = false
            let finish: (UUID?) -> Void = { value in
                guard !finished else { return }
                finished = true
                panel.orderOut(nil)
                continuation.resume(returning: value)
            }
            panel.contentView = NSHostingView(rootView: ExternalQuestion(
                icon: NSWorkspace.shared.icon(forFile: launcher.path), title: title, message: message, caution: caution, items: items,
                decline: decline, accept: accept, finish: finish))
            panel.setContentSize(panel.contentView!.fittingSize)
            panel.center()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            Task { try? await Task.sleep(for: Self.timeout); finish(nil) }
        }
        return answer
    }
}

struct ExternalQuestion: View {
    let icon: NSImage
    let title: String
    let message: String?
    let caution: String?
    let items: [ExternalItem]
    let decline: String
    let accept: String
    let finish: (UUID?) -> Void
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if let message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let caution {
                        Label(caution, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !items.isEmpty {
                List(items, selection: $selection) { item in
                    Label(item.name, systemImage: item.symbol).tag(item.id)
                }
                .frame(height: min(CGFloat(items.count) * 28 + 12, 220))
                .clipShape(.rect(cornerRadius: 8))
            }
            HStack {
                Spacer()
                // The window comes forward while the person may be typing elsewhere, so Return declines
                // and only a click allows.
                Button(decline) { finish(nil) }.keyboardShortcut(.defaultAction)
                Button(accept) { finish(items.isEmpty ? UUID() : selection) }
                    .disabled(!items.isEmpty && selection == nil)
            }
        }
        .onExitCommand { finish(nil) }
        .padding(20)
        .frame(width: 400)
    }
}

/// Settings > Agents: the master switch, how to add the tool to an agent, and a row for each
/// allowed app that opens a sheet with a switch for every item it may use.
public struct ExternalToolsSettingsView: View {
    @ObservedObject var gate: ExternalGate
    let noun: String
    let items: [ExternalItem]
    let command: String
    let server: String
    let delete: ([UUID]) -> Void
    @State private var removing: ExternalCaller?
    @State private var editing: UUID?
    @State private var shownCommands: Set<String> = []

    /// `command` is the tool's path; `server` the name agents know it by; `delete` removes items
    /// an app made when the person removes the app and its items.
    public init(gate: ExternalGate, noun: String, items: [ExternalItem], command: String, server: String,
                delete: @escaping ([UUID]) -> Void) {
        self.gate = gate; self.noun = noun; self.items = items; self.command = command; self.server = server; self.delete = delete
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Allow agents", isOn: Binding(get: { gate.enabled }, set: { gate.enabled = $0 }))
                if let failure = gate.failure { Text(failure).foregroundStyle(.red) }
            }
            if gate.enabled {
                Section("Set Up") {
                    commandRow("Command", "\"\(command)\"")
                    commandRow("Claude Code", "claude mcp add --scope user \(server) -- \"\(command)\" mcp")
                    commandRow("Codex", "codex mcp add \(server) -- \"\(command)\" mcp")
                }
            }
            if !gate.grants.callers.isEmpty {
                Section("Allowed") {
                    ForEach(gate.grants.callers) { caller in callerRow(caller) }
                }
            }
        }
        .formStyle(.grouped)
        // Looked up afresh so the sheet closes once its app is removed.
        .sheet(item: Binding(get: { gate.grants.callers.first { $0.id == editing } }, set: { editing = $0?.id })) { caller in
            ExternalCallerSheet(gate: gate, caller: caller, noun: noun, items: items,
                                remove: { removing = caller }, done: { editing = nil })
                .removeDialog($removing, gate: gate, noun: noun, items: items, delete: delete)
        }
        .removeDialog($removing, gate: gate, noun: noun, items: items, delete: delete)
    }

    private func callerRow(_ caller: ExternalCaller) -> some View {
        let allowed = items.filter { gate.allows(caller.id, $0.id) }.count
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: caller.launcher.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(caller.launcher.name)
                    if caller.launcher.caution != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(caller.launcher.caution ?? "")
                    }
                }
                Text(allowed == 0 ? "No \(noun)s" : "\(allowed) \(allowed == 1 ? noun : noun + "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Remove", role: .destructive) { removing = caller }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
        }
        .contentShape(.rect)
        .onTapGesture { editing = caller.id }
        .help(caller.launcher.path)
    }

    /// Set out like the installation and update commands in Noodle's Settings: the command
    /// shows only once asked for.
    private func commandRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Instructions") {
                    if shownCommands.remove(title) == nil { shownCommands.insert(title) }
                }
                .buttonStyle(.link)
            }
            if shownCommands.contains(title) { commandBox(text) }
        }
    }

    private func commandBox(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy Command", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy command")
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
    }
}

/// The switches for one allowed app.
struct ExternalCallerSheet: View {
    @ObservedObject var gate: ExternalGate
    let caller: ExternalCaller
    let noun: String
    let items: [ExternalItem]
    let remove: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: caller.launcher.path)).resizable().frame(width: 32, height: 32)
                Text(caller.launcher.name).font(.headline).help(caller.launcher.path)
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            Form {
                if let caution = caller.launcher.caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
                Section {
                    if items.isEmpty { Text("No \(noun)s").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        Toggle(isOn: Binding(get: { gate.allows(caller.id, item.id) },
                                             set: { gate.setAccess($0, to: item.id, for: caller.id) })) {
                            Label {
                                Text(item.name)
                                if gate.created(caller.id, item.id) { Text("Created by \(caller.launcher.name)") }
                            } icon: { Image(systemName: item.symbol) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 120, idealHeight: min(CGFloat(max(items.count, 1)) * 44 + 40, 420))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Remove", role: .destructive, action: remove)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }
}

private extension View {
    /// Asks before removing an app, offering to delete the items it made.
    func removeDialog(_ removing: Binding<ExternalCaller?>, gate: ExternalGate, noun: String, items: [ExternalItem],
                      delete: @escaping ([UUID]) -> Void) -> some View {
        confirmationDialog("Remove \(removing.wrappedValue?.launcher.name ?? "")?",
                           isPresented: Binding(get: { removing.wrappedValue != nil }, set: { if !$0 { removing.wrappedValue = nil } }),
                           presenting: removing.wrappedValue) { caller in
            let made = caller.resources.filter(\.created).map(\.id).filter { id in items.contains { $0.id == id } }
            if made.isEmpty {
                Button("Remove", role: .destructive) { gate.remove(caller.id) }
            } else {
                Button("Remove and Delete \(made.count) \(made.count == 1 ? noun.capitalized : noun.capitalized + "s")", role: .destructive) {
                    gate.remove(caller.id); delete(made)
                }
                Button("Remove and Keep \(made.count == 1 ? noun.capitalized : noun.capitalized + "s")") { gate.remove(caller.id) }
            }
        } message: { caller in
            Text("\(caller.launcher.name) will be asked about again before it can connect.")
        }
    }
}
