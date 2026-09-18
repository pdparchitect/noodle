import NoodleWallpaper
import SwiftUI

struct BrowserBackgroundSheet: View {
    let original: BackgroundSelection
    let imageURL: URL?
    let onApply: (ConversationBackground, PreparedBackgroundFile?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: BackgroundSelection
    @State private var busy = false
    @State private var failure: String?

    init(background: ConversationBackground, imageURL: URL?, file: PreparedBackgroundFile? = nil,
         onApply: @escaping (ConversationBackground, PreparedBackgroundFile?) throws -> Void) {
        original = BackgroundSelection(background: background, file: file)
        self.imageURL = imageURL; self.onApply = onApply
        _selection = State(initialValue: original)
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                Text("Background").font(.headline).foregroundStyle(.primary)
                Spacer()
                Button("Apply") {
                    busy = true; failure = nil
                    Task {
                        defer { busy = false }
                        do {
                            try onApply(selection.background, selection.file)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .foregroundStyle(.blue)
                .disabled(busy || selection == original)
            }.buttonStyle(.plain)
            ConversationBackgroundView(background: selection.background,
                imageURL: selection.file?.url ?? (selection.background.imageFilename == nil ? nil : imageURL))
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
        .noodleSheetSizing()
        .interactiveDismissDisabled(busy)
    }
}
