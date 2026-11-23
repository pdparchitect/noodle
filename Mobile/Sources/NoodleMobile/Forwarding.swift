import HubLink
import SwiftUI

extension EnvironmentValues {
    /// Opens Forward… for a file, or Use as Background's Choose Conversations…, presented by the conversation rather
    /// than the file pressed, which the conversation may unload.
    @Entry var forwardAttachment: (@MainActor (AttachmentForwardRequest) -> Void)?
    /// Every Hub this phone joined, whose bots and groups a file can be forwarded to.
    @Entry var joinedHubs: [HubChats] = []
}

/// Forward…: a file of one conversation sent on to another bot or group.
enum AttachmentForwarding {
    /// Files only: a recording, a comment on another file and a link stay where they were made.
    static func canForward(_ attachment: LinkAttachment) -> Bool {
        attachment.url == nil && attachment.voice == nil && attachment.annotation == nil
    }

    /// Where a file can go: the bots and groups the list shows on every joined Hub, ordered as All orders
    /// them, but the file's own conversation and those that take no messages now. Search finds them by name.
    @MainActor static func targets(in hubs: [HubChats], leaving source: UUID, search: String) -> [(HubChats, HubThread)] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = hubs.flatMap { hub in
            hub.listedThreads.filter { thread in
                thread.conversationID != source && hub.composerUnavailableReason(for: thread) == nil
                    && (term.isEmpty || thread.name.localizedStandardContains(term))
            }
            .map { thread in (hub, thread) }
        }
        return HubChats.sorted(open)
    }
}

/// A file to forward, or to use as the background of the conversations chosen, and the conversation it is in.
struct AttachmentForwardRequest: Identifiable {
    enum Purpose { case forward, useAsBackground }

    let id = UUID()
    let chats: HubChats
    let thread: HubThread
    let attachment: LinkAttachment
    var purpose = Purpose.forward
}

/// Picks the bot or group a file goes to, with an optional comment, and sends it there, as the share sheet does.
/// Use as Background's Choose Conversations… picks several the same way and sets the file as each one's background.
struct ForwardSheet: View {
    let request: AttachmentForwardRequest
    let hubs: [HubChats]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var comment = ""
    /// In the order chosen.
    @State private var chosen: [ChatLink] = []
    @State private var sending = false
    @State private var problem: String?

    private struct Target: Identifiable {
        let chats: HubChats
        let thread: HubThread
        let id: ChatLink
    }

    private func targets(matching search: String) -> [Target] {
        AttachmentForwarding.targets(in: hubs, leaving: request.thread.conversationID, search: search).map { hub, thread in
            Target(chats: hub, thread: thread, id: ChatLink(hub: CurrentHub.name(of: hub.pairing), thread: thread.id))
        }
    }

    private var choosesSeveral: Bool { request.purpose == .useAsBackground }

    var body: some View {
        let targets = self.targets(matching: search)
        // A search that hides the chosen one leaves nothing to send to, so Send never goes somewhere unseen.
        let target = targets.first { $0.id == chosen.first }
        NavigationStack {
            List {
                Section {
                    Label(request.attachment.filename, systemImage: "doc")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !choosesSeveral {
                        TextField("Comment", text: $comment, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                Section {
                    ForEach(targets) { target in
                        Button { choose(target) } label: { row(target) }
                            .buttonStyle(.plain)
                    }
                    if targets.isEmpty {
                        Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Bots" : "No Results")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchField(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .disabled(sending)
            .navigationTitle(choosesSeveral ? "Use as Background" : "Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else if choosesSeveral {
                        Button("Use", action: useAsBackground)
                            .disabled(chosen.isEmpty)
                    } else {
                        Button("Send") { if let target { send(to: target) } }
                            .disabled(target == nil)
                    }
                }
            }
            // Once sending, the message goes whatever happens to the sheet, so it cannot be cancelled.
            .interactiveDismissDisabled(sending)
        }
    }

    private func row(_ target: Target) -> some View {
        HStack(spacing: 12) {
            ThreadAvatar(chats: target.chats, thread: target.thread, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.thread.name).lineLimit(1)
                // Several Hubs' bots may share a name, so each says its Hub.
                if hubs.count > 1 {
                    Text(target.chats.pairing.hubName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if chosen.contains(target.id) {
                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(chosen.contains(target.id) ? .isSelected : [])
    }

    /// Forward… sends to one; several chosen for a background stay chosen while searching for the next.
    private func choose(_ target: Target) {
        if !choosesSeveral { chosen = [target.id] }
        else if chosen.contains(target.id) { chosen.removeAll { $0 == target.id } }
        else { chosen.append(target.id) }
    }

    /// Closes once every one chosen has it, on whichever Hub it is; else stays open, saying why, such as a shader
    /// that does not compile.
    private func useAsBackground() {
        let all = self.targets(matching: "")
        let chosenTargets = chosen.compactMap { link in all.first { $0.id == link }.map { ($0.chats, $0.thread) } }
        sending = true
        problem = nil
        let request = request
        Task {
            do {
                try await request.chats.useAsBackground(request.attachment, in: request.thread, for: chosenTargets)
                dismiss()
            } catch {
                problem = error.localizedDescription
                sending = false
            }
        }
    }

    /// Closes once the message shows in the other conversation, which may first wait for the file to come
    /// down from the Hub; it then goes as any message does, saying there if it did not get through.
    private func send(to target: Target) {
        sending = true
        problem = nil
        let request = request, comment = comment
        Task {
            do {
                let id = try await target.chats.forward(request.attachment, from: request.chats, in: request.thread,
                                                        saying: comment, to: target.thread)
                dismiss()
                await target.chats.deliver(id)
            } catch {
                problem = error.localizedDescription
                sending = false
            }
        }
    }
}
