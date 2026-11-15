import AppKit
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import PionCore
import SwiftUI

/// Pion's first launch, in the main window, as Noodle's: Pion's mark appears, then Noodle's own steps to get an
/// account ready, which make the starter team and the group they share. Leaving counts as Not Now, and Help >
/// Welcome brings it back.
struct WelcomeView: View {
    let model: PionModel
    let setup: HarnessSetupController
    @State private var shown = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                PionSymbol()
                    .frame(width: 72, height: 72)
                Text("Welcome to \(pionAppName)")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if shown {
                // Noodle's own steps, with Pion's accounts and its investigation team.
                FirstBotSetupSteps(
                    setup: setup, runtime: model.runtime, accounts: PionHarnesses.featured,
                    makeTeam: { provider in
                        do {
                            return try model.createStarterTeamIfFirst(on: provider).map { ($0.team, $0.group.id) }
                        } catch {
                            model.problem = error.localizedDescription
                            return ([], nil)
                        }
                    },
                    introduce: { model.introduceStarterTeam(in: $0) },
                    finish: { model.finishWelcome() },
                    picture: { AnyView(AgentMark(agent: $0, size: 64)) },
                    roles: PionStarterTeam.members.map(\.role),
                    columnWidth: 160)
                    .transition(.opacity.combined(with: .offset(y: 24)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.smooth(duration: 0.5)) { shown = true }
        }
    }
}

/// Pion's mark, drawn in the text colour.
private struct PionSymbol: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "AppSymbol", withExtension: "svg").flatMap {
        let image = NSImage(contentsOf: $0)
        image?.isTemplate = true
        return image
    }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().foregroundStyle(.primary).accessibilityHidden(true)
        } else {
            Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}
