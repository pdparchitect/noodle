import SwiftUI
import NoodleCore

struct ConversationBackgroundSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: BotConversation
    /// The enclosing editor owns imported media until Save or Cancel.
    var draft: Binding<BackgroundSelection?>? = nil
    @State private var selection = BackgroundSelection()
    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false
    @State private var original: BackgroundSelection?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .disabled(busy)
                Spacer()
                Text("Conversation Background").font(.headline)
                Spacer()
                Button("Apply") {
                    if let draft {
                        draft.wrappedValue = selection
                        dismiss()
                        return
                    }
                    busy = true
                    Task {
                        do {
                            try await store.setBackground(selection.background, imageData: nil, file: selection.file, for: conversation)
                            dismiss()
                        } catch { failure = error.localizedDescription; busy = false }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(busy || selection == original)
                .keyboardShortcut(.defaultAction)
            }
            Text(store.title(for: conversation)).foregroundStyle(.secondary)
            ZStack {
                ConversationBackgroundView(background: selection.background,
                    imageURL: selection.file?.url ?? store.repository.backgroundImageURL(selection.background, conversationID: conversation.id))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Make this space your own.").padding(10).background(.regularMaterial, in: Capsule())
                    HStack { Spacer(); Text("Looks good!").padding(10).background(.regularMaterial, in: Capsule()) }
                }.padding(24)
            }
            .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 16))
            .backgroundDropTarget(isBusy: $busy, failure: $failure) { selection = .imported($0); failure = nil }
            BackgroundPicker(selection: $selection, busy: $busy, failure: $failure)
            if busy { ProgressView().controlSize(.small) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let initial = draft?.wrappedValue ?? BackgroundSelection(background: store.background(for: conversation))
            original = initial
            selection = initial
        }
        .onDisappear { selection.file = nil }
        .interactiveDismissDisabled(busy)
    }
}

struct ConversationBackgroundSettingsRow: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    @Binding var draft: BackgroundSelection?
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack {
                Label("Conversation Background", systemImage: "photo")
                Spacer()
                Text((draft?.background ?? store.background(for: conversation)).isDefault ? "Default" : "Custom")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) {
            ConversationBackgroundSheet(conversation: conversation, draft: $draft)
                .environment(store)
                .noodleSheetSizing()
        }
    }
}
