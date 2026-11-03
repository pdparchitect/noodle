import SwiftUI

extension View {
    /// The system's search field on iPhone and iPad. On a Mac it is a plain field over the content instead:
    /// there the system's search stops the app as it opens, when UIKit lays out its search and asks for the
    /// screen, which an iPad app on a Mac may not do.
    func searchField(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: String = "Search",
                     focus: FocusState<Bool>.Binding? = nil) -> some View {
        modifier(SearchField(text: text, placement: placement, prompt: prompt, focus: focus))
    }
}

private struct SearchField: ViewModifier {
    @Binding var text: String
    let placement: SearchFieldPlacement
    let prompt: String
    let focus: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            content.safeAreaInset(edge: .top, spacing: 0) { field }
        } else if let focus {
            content.searchable(text: $text, placement: placement, prompt: prompt).searchFocused(focus)
        } else {
            content.searchable(text: $text, placement: placement, prompt: prompt)
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            focused(TextField(prompt, text: $text).textFieldStyle(.plain).autocorrectionDisabled())
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func focused(_ field: some View) -> some View {
        if let focus { field.focused(focus) } else { field }
    }
}
