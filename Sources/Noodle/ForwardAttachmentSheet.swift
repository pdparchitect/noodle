import NoodleCore
import SwiftUI

extension EnvironmentValues {
    /// Opens Forward… for a file, presented by the conversation rather than the message it is in.
    @Entry var forwardAttachment: (@MainActor (ConversationAttachment) -> Void)?
}

/// A conversation Forward… can send to.
struct ForwardTarget: Identifiable {
    let id: UUID
    let title: String
}

/// Forward…: picks the conversation a file goes to, with an optional comment, and sends it there. The app
/// gives the conversations a search finds, each one's picture and the sending.
struct ForwardAttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: ConversationAttachment
    let targets: (String) -> [ForwardTarget]
    /// A conversation's picture, 28 points across.
    let picture: (UUID) -> AnyView
    let send: (UUID, String) async throws -> Void
    @State private var search = ""
    @State private var chosenID: UUID?
    @State private var comment = ""
    @State private var failure: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let targets = targets(search)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Forward").font(.headline)
                Spacer()
                Button("Send", action: forward)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(chosenID == nil)
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
            TextField("Comment", text: $comment)
                .textFieldStyle(.roundedBorder)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { searchFocused = true }
        // A search that hides the chosen one leaves nothing chosen, so Send never goes somewhere unseen.
        .onChange(of: targets.map(\.id)) { _, shown in
            if let chosenID, !shown.contains(chosenID) { self.chosenID = nil }
        }
    }

    private func row(_ item: ForwardTarget) -> some View {
        let chosen = chosenID == item.id
        return Button { chosenID = item.id } label: {
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

    private func forward() {
        guard let chosenID else { return }
        Task {
            do {
                try await send(chosenID, comment)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
