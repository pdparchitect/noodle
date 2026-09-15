import SwiftUI
import NoodleWallpaperCore

public extension View {
    /// Make the whole preview accept media, including wallpaper views that ignore input.
    func backgroundDropTarget(isBusy: Binding<Bool>, failure: Binding<String?>,
                              onLoad: @escaping (PreparedBackgroundFile) -> Void) -> some View {
        modifier(BackgroundDropTarget(isBusy: isBusy, failure: failure, onLoad: onLoad))
    }
}

private struct BackgroundDropTarget: ViewModifier {
    @Binding var isBusy: Bool
    @Binding var failure: String?
    let onLoad: (PreparedBackgroundFile) -> Void
    @State private var isTargeted = false
    @State private var importTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.overlay {
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onDrop(of: BackgroundDrop.contentTypes, isTargeted: $isTargeted, perform: drop)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isTargeted && !isBusy ? Color.accentColor : .clear, lineWidth: 3)
                .allowsHitTesting(false)
        }
        .help("Drop an image or video to use as the background")
        .onDisappear { importTask?.cancel(); importTask = nil }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !isBusy, let provider = providers.first(where: BackgroundDrop.accepts) else { return false }
        isBusy = true
        failure = nil
        importTask = Task { @MainActor in
            defer { isBusy = false }
            do {
                let file = try await BackgroundDrop.load(provider)
                try Task.checkCancellation()
                onLoad(file)
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        return true
    }
}
