import AppKit
import QuickLook
import SwiftUI

@main struct PreviewProof: App {
    var body: some Scene {
        WindowGroup("Computer Preview Proof") {
            ProofView().frame(width: 520, height: 260)
        }
    }
}

struct ProofView: View {
    @State private var preview: URL?
    @State private var file: URL?
    var body: some View {
        VStack(spacing: 20) {
            Text("Existing SwiftUI Quick Look mechanics").font(.headline)
            Button("Preview Computer") { preview = file }
                .keyboardShortcut(.space, modifiers: [])
            Text("No guest is started. Test typing, Space and Escape inside the preview.")
                .font(.caption)
        }
        .quickLookPreview($preview)
        .task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Computer.noodlepreviewproof")
            try? Data("{}".utf8).write(to: url)
            file = url
        }
    }
}
