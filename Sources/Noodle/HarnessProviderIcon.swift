import SwiftUI
import NoodleCore

/// A provider-owned mark rather than a generic terminal symbol.
struct HarnessProviderIcon: View {
    let provider: HarnessProvider

    var body: some View {
        switch provider {
        case .codex:
            Image("CodexHarness")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        }
    }
}
