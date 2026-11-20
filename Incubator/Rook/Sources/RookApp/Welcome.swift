import AppKit
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import RookCore
import SwiftUI

/// Rook's first launch, in the main window, as Noodle's: Rook's mark appears, then Noodle's own steps to get an
/// account ready, which make the starter team and the group they share. Leaving counts as Not Now, and Help >
/// Welcome brings it back.
struct WelcomeView: View {
    let model: RookModel
    let setup: HarnessSetupController
    @State private var shown = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                RookSymbol()
                    .frame(width: 72, height: 72)
                Text("Welcome to \(rookAppName)")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if shown {
                // Noodle's own steps, with Rook's accounts and its mission team.
                FirstBotSetupSteps(
                    setup: setup, runtime: model.runtime, accounts: RookHarnesses.featured,
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
                    roles: RookStarterTeam.members.map(\.role),
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

/// Rook's mark, drawn in the text colour, or in `ink` where it is set on a card of its own.
struct RookSymbol: View {
    var ink: Color = .primary

    private static let image: NSImage? = Bundle.main.url(forResource: "AppSymbol", withExtension: "svg").flatMap {
        let image = NSImage(contentsOf: $0)
        image?.isTemplate = true
        return image
    }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().foregroundStyle(ink).accessibilityHidden(true)
        } else {
            Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}
