import AppKit
import SwiftUI
import NoodleCore

/// A provider-owned mark rather than a generic terminal symbol.
struct HarnessProviderIcon: View {
    let provider: HarnessProvider

    var body: some View {
        switch provider {
        case .codex:
            codexImage
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        }
    }

    private var codexImage: Image {
        guard let url = Bundle.main.url(forResource: "CodexHarness", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return Image(systemName: "apple.terminal")
        }
        image.isTemplate = true
        return Image(nsImage: image)
    }
}
