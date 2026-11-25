import AppKit
import NoodleBrand
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
        VStack(spacing: 36) {
            StampedWordmark(letters: PionWordmark.letters, capHeight: PionWordmark.capHeight,
                            spacing: PionWordmark.spacing, height: 64) {
                withAnimation(.smooth(duration: 0.5)) { shown = true }
            }
            .foregroundStyle(Color("AccentColor"))
            .accessibilityElement()
            .accessibilityLabel("Welcome to \(pionAppName)")
            .accessibilityAddTraits(.isHeader)
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
    }
}

/// Pion's name in the banner's letters: square-cut, with octagonal bowls.
enum PionWordmark {
    static let capHeight: CGFloat = 140
    static let spacing: CGFloat = 16
    private static let stem: CGFloat = 26

    static let letters: [StampedWordmark.Letter] = {
        typealias Letter = StampedWordmark.Letter
        let t = stem
        let p = Letter(width: 100, parts: [Letter.polygon([(0, 0), (76, 0), (100, 24), (100, 64), (76, 88), (t, 88), (t, 140), (0, 140)])],
                       holes: [Letter.polygon([(t, t), (64, t), (74, 36), (74, 52), (64, 62), (t, 62)])])
        let i = Letter(width: 84, parts: [Path(CGRect(x: 0, y: 0, width: 84, height: t)),
                                          Path(CGRect(x: 0, y: 140 - t, width: 84, height: t)),
                                          Path(CGRect(x: 42 - t / 2, y: 0, width: t, height: 140))])
        let o = Letter(width: 110, parts: [Letter.octagon(CGRect(x: 0, y: 0, width: 110, height: 140), cut: 32)],
                       holes: [Letter.octagon(CGRect(x: t, y: t, width: 110 - 2 * t, height: 140 - 2 * t), cut: 14)])
        let n = Letter(width: 110, parts: [Path(CGRect(x: 0, y: 0, width: t, height: 140)),
                                           Path(CGRect(x: 110 - t, y: 0, width: t, height: 140)),
                                           Letter.polygon([(0, 0), (34, 0), (110, 140), (76, 140)])])
        return [p, i, o, n]
    }()
}

/// Pion's mark, drawn in the text colour, or in `ink` where it is set on a card of its own.
struct PionSymbol: View {
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
