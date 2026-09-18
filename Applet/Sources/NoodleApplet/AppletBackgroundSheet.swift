import NoodleWallpaper
import SwiftUI

struct AppletBackgroundSheet: View {
    @ObservedObject var store: AppletBackgroundStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: BackgroundSelection
    @State private var busy = false
    @State private var failure: String?

    init(store: AppletBackgroundStore) {
        self.store = store
        _selection = State(initialValue: BackgroundSelection(background: store.background))
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                Text("Library Background").font(.headline).foregroundStyle(.primary)
                Spacer()
                Button("Apply") {
                    busy = true; failure = nil
                    Task {
                        defer { busy = false }
                        do {
                            try await store.apply(selection.background, file: selection.file)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .foregroundStyle(.blue)
                .disabled(busy || selection == BackgroundSelection(background: store.background))
            }.buttonStyle(.plain)
            ConversationBackgroundView(background: selection.background,
                imageURL: selection.file?.url ?? (selection.background.imageFilename == nil ? nil : store.imageURL))
                .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 16))
                .backgroundDropTarget(isBusy: $busy, failure: $failure) { selection = .imported($0); failure = nil }
            BackgroundPicker(selection: $selection, busy: $busy, failure: $failure)
            if busy { ProgressView().controlSize(.small) }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24).frame(width: 520).controlSize(.regular)
        .fixedSize(horizontal: false, vertical: true).presentationSizing(.fitted)
        .interactiveDismissDisabled(busy)
    }
}
