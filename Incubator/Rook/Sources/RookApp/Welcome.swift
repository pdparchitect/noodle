import AppKit
import NoodleBrand
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
        VStack(spacing: 36) {
            StampedWordmark(letters: RookWordmark.letters, capHeight: RookWordmark.capHeight,
                            spacing: RookWordmark.spacing, height: 64) {
                withAnimation(.smooth(duration: 0.5)) { shown = true }
            }
            .foregroundStyle(Color("AccentColor"))
            .accessibilityElement()
            .accessibilityLabel("Welcome to \(rookAppName)")
            .accessibilityAddTraits(.isHeader)
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
    }
}

/// Rook's name in the banner's letters: square-cut, with octagonal bowls and an R whose stem is slashed.
enum RookWordmark {
    static let capHeight: CGFloat = 140
    static let spacing: CGFloat = 16
    private static let stem: CGFloat = 26

    static let letters: [StampedWordmark.Letter] = {
        typealias Letter = StampedWordmark.Letter
        let t = stem
        let r = Letter(width: 110, parts: [Letter.polygon([(0, 0), (80, 0), (104, 24), (104, 62), (80, 86), (0, 86)]),
                                           Path(CGRect(x: 0, y: 0, width: t, height: 140)),
                                           Letter.polygon([(44, 60), (76, 60), (110, 140), (78, 140)])],
                       holes: [Letter.polygon([(t, t), (68, t), (78, 36), (78, 50), (68, 60), (t, 60)]),
                               Letter.polygon([(-2, 112), (t + 2, 98), (t + 2, 106), (-2, 120)])])
        let o = Letter(width: 110, parts: [Letter.octagon(CGRect(x: 0, y: 0, width: 110, height: 140), cut: 32)],
                       holes: [Letter.octagon(CGRect(x: t, y: t, width: 110 - 2 * t, height: 140 - 2 * t), cut: 14)])
        let k = Letter(width: 110, parts: [Path(CGRect(x: 0, y: 0, width: t, height: 140)),
                                           Letter.polygon([(t, 58), (74, 0), (110, 0), (t, 100)]),
                                           Letter.polygon([(44, 74), (66, 50), (110, 140), (72, 140)])])
        return [r, o, o, k]
    }()
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
