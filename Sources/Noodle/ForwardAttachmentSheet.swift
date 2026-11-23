import NoodleCore
import SwiftUI

extension EnvironmentValues {
    /// Opens Forward… for a file, or Use as Background's Choose Conversations…, presented by the conversation rather
    /// than the message it is in.
    @Entry var forwardAttachment: (@MainActor (AttachmentForwardRequest) -> Void)?
}

/// A file to forward, or to use as the background of the conversations chosen.
struct AttachmentForwardRequest: Identifiable {
    enum Purpose { case forward, useAsBackground }

    let id = UUID()
    let attachment: ConversationAttachment
    var purpose = Purpose.forward
}

/// A conversation Forward… can send to.
struct ForwardTarget: Identifiable {
    let id: UUID
    let title: String
}

/// Forward…: picks the conversation a file goes to, with an optional comment, and sends it there. Use as
/// Background's Choose Conversations… picks several the same way and sets the file as each one's background. The app
/// gives the conversations a search finds, each one's picture, and what is done with those chosen.
struct ForwardAttachmentSheet: View {
    /// What is done with the conversations chosen.
    enum Action {
        /// Forward…: the file goes to the one chosen, with the comment.
        case send((UUID, String) async throws -> Void)
        /// Use as Background: it becomes the background of each one chosen.
        case useAsBackground(([UUID]) async throws -> Void)
    }

    @Environment(\.dismiss) private var dismiss
    let attachment: ConversationAttachment
    let targets: (String) -> [ForwardTarget]
    /// A conversation's picture, 28 points across.
    let picture: (UUID) -> AnyView
    let action: Action
    @State private var search = ""
    /// In the order chosen.
    @State private var chosenIDs: [UUID] = []
    @State private var comment = ""
    @State private var failure: String?
    @FocusState private var searchFocused: Bool

    private var choosesSeveral: Bool {
        if case .useAsBackground = action { true } else { false }
    }

    var body: some View {
        let targets = targets(search)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(choosesSeveral ? "Use as Background" : "Forward").font(.headline)
                Spacer()
                Button(choosesSeveral ? "Use" : "Send", action: finish)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(chosenIDs.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            Label(attachment.originalFilename, systemImage: "doc")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(targets) { row($0) }
                }
            }
            .frame(height: 240)
            .overlay {
                if targets.isEmpty { Text("No Conversations").foregroundStyle(.secondary) }
            }
            if !choosesSeveral {
                TextField("Comment", text: $comment)
                    .textFieldStyle(.roundedBorder)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { searchFocused = true }
        // A search that hides the chosen one leaves nothing chosen, so Send never goes somewhere unseen. Several
        // chosen for a background stay chosen while searching for the next.
        .onChange(of: targets.map(\.id)) { _, shown in
            if !choosesSeveral { chosenIDs.removeAll { !shown.contains($0) } }
        }
    }

    private func row(_ item: ForwardTarget) -> some View {
        let chosen = chosenIDs.contains(item.id)
        return Button {
            if !choosesSeveral { chosenIDs = [item.id] }
            else if chosen { chosenIDs.removeAll { $0 == item.id } }
            else { chosenIDs.append(item.id) }
        } label: {
            HStack(spacing: 10) {
                picture(item.id)
                Text(item.title).lineLimit(1)
                Spacer()
                if chosen {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(chosen ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func finish() {
        guard let first = chosenIDs.first else { return }
        let chosenIDs = chosenIDs, comment = comment
        Task {
            do {
                switch action {
                case .send(let send): try await send(first, comment)
                case .useAsBackground(let use): try await use(chosenIDs)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
