import SwiftUI
import NoodleCore

/// A provider-owned mark rather than a generic terminal symbol.
struct HarnessProviderIcon: View {
    let provider: HarnessProvider

    var body: some View {
        (provider == .apple ? Image(systemName: "apple.logo") : Image(assetName))
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
    }

    private var assetName: String {
        switch provider {
        case .apple:
            ""
        case .codex:
            "CodexHarness"
        case .claudeCode:
            "ClaudeHarness"
        case .fx:
            "FxHarness"
        case .grokBuild:
            "GrokHarness"
        case .muse:
            "MuseHarness"
        }
    }
}
