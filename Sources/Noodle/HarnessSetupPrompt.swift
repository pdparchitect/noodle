import SwiftUI

struct HarnessSetupPrompt: View {
    let openSetup: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Install a harness to get started.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Set Up Harness", action: openSetup)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}
