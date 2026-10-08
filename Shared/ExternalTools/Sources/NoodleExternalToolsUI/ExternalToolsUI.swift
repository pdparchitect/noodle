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

/// Settings > External Tools: the master switch, how to add the tool to an agent, and one
/// section for each allowed app with a switch for every item it may use.
public struct ExternalToolsSettingsView: View {
    @ObservedObject var gate: ExternalGate
    let noun: String
    let items: [ExternalItem]
    let command: String
    let server: String
    let delete: ([UUID]) -> Void
    @State private var removing: ExternalCaller?

    /// `command` is the tool's path; `server` the name agents know it by; `delete` removes items
    /// an app made when the person removes the app and its items.
    public init(gate: ExternalGate, noun: String, items: [ExternalItem], command: String, server: String,
                delete: @escaping ([UUID]) -> Void) {
        self.gate = gate; self.noun = noun; self.items = items; self.command = command; self.server = server; self.delete = delete
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Allow external tools", isOn: Binding(get: { gate.enabled }, set: { gate.enabled = $0 }))
                if let failure = gate.failure { Text(failure).foregroundStyle(.red) }
            }
            Section("Set Up") {
                commandRow("Command", "\"\(command)\"")
                commandRow("Claude Code", "claude mcp add --scope user \(server) -- \"\(command)\" mcp")
                commandRow("Codex", "codex mcp add \(server) -- \"\(command)\" mcp")
            }
            ForEach(gate.grants.callers) { caller in
                Section {
                    if let caution = caller.launcher.caution {
                        Label(caution, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    }
                    ForEach(items) { item in
                        Toggle(isOn: Binding(get: { gate.allows(caller.id, item.id) },
                                             set: { gate.setAccess($0, to: item.id, for: caller.id) })) {
                            Label {
                                Text(item.name)
                                if gate.created(caller.id, item.id) { Text("Created by \(caller.launcher.name)") }
                            } icon: { Image(systemName: item.symbol) }
                        }
                    }
                    Button("Remove \(caller.launcher.name)", role: .destructive) { removing = caller }.buttonStyle(.link)
                } header: {
                    Text(caller.launcher.name).help(caller.launcher.path)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(removing?.launcher.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { caller in
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

    private func commandRow(_ title: String, _ text: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(text).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.buttonStyle(.link)
            }
        }
    }
}
