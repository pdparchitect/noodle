import SwiftUI

/// The same top action bar as Noodle. Return stays with the focused text field.
struct SheetHeader: View {
    var heading = ""
    let title: String
    let enabled: Bool
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text(heading).font(.headline)
            Spacer()
            Button(title, action: action)
                .buttonStyle(.plain)
                .foregroundStyle(enabled ? Color.blue : .secondary)
                .disabled(!enabled)
        }
        .padding(16)
    }
}

