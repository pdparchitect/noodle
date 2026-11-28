#if NOODLE_DEV_HOOKS
import Foundation

// MARK: - Film

/// Titles around a scenario, so a recording opens and closes the same way every time. The apps that play
/// scenarios share it, with their own closing mark; each draws it its own way.
public struct ScenarioFilm: Codable {
    /// What is behind the app and under the titles: "black", "white", or a picture
    /// or video, named as an asset in the scenario folder or as a web address.
    public var background: String?
    /// The backdrop around the window, as a share of its shorter side; a film's 0.07 when left out. Stills for a
    /// README want more of it.
    public var margin: Double?
    public var intro: Intro?
    public var outro: Outro?

    public init(background: String? = nil, margin: Double? = nil, intro: Intro? = nil, outro: Outro? = nil) {
        self.background = background
        self.margin = margin
        self.intro = intro
        self.outro = outro
    }

    public struct Intro: Codable {
        /// A picture to bring up under the title, shown in a circle. Any asset in the
        /// scenario folder, so it can be a bot's own avatar or anything else.
        public var icon: String?
        /// "white" or "black", for a mark that is drawn in the wrong one.
        public var iconTint: String?
        /// The small line above the title, for what this is a scenario of.
        public var kicker: String?
        /// Defaults to the scenario's own title.
        public var title: String?
        public var subtitle: String?
        /// Seconds to stay on the finished card. Default 1.4.
        public var hold: Double?

        public init(icon: String? = nil, iconTint: String? = nil, kicker: String? = nil, title: String? = nil,
                    subtitle: String? = nil, hold: Double? = nil) {
            self.icon = icon
            self.iconTint = iconTint
            self.kicker = kicker
            self.title = title
            self.subtitle = subtitle
            self.hold = hold
        }
    }

    public struct Outro: Codable {
        public var tagline: String?
        /// Seconds to stay on the finished mark. Default 1.6.
        public var hold: Double?

        public init(tagline: String? = nil, hold: Double? = nil) {
            self.tagline = tagline
            self.hold = hold
        }
    }

    public enum Stage { case intro, outro }

    public static let tints: Set<String> = ["white", "black", "none"]

    /// What a recording can move in on.
    public static let focusRegions: Set<String> = ["composer", "transcript", "none"]

    public var isLight: Bool { background == "white" }
    /// The picture or video behind everything, if the background is not just a colour.
    public var media: String? {
        let value = background ?? "black"
        return ["black", "white"].contains(value) ? nil : value
    }

    /// The film as a launch asks for it, so one scenario can be recorded in different ways without editing it.
    /// `background`, from `--scenario-background`, replaces what is behind the app, making a film of only that
    /// for a scenario without one; `without`, from `--scenario-without`, leaves out title cards.
    /// `margin`, from `--scenario-margin`, widens the backdrop around the window.
    public static func adjusted(_ film: ScenarioFilm?, background: String?, without: String?, margin: String? = nil,
                                media: (String) throws -> URL) throws -> ScenarioFilm? {
        var film = film
        if let background {
            _ = try media(background)
            film = film ?? ScenarioFilm()
            film?.background = background
        }
        if let margin {
            guard let value = Double(margin), (0...0.5).contains(value) else {
                throw ScenarioError("\(margin) is not a margin; give a share of the window's shorter side, from 0 to 0.5.")
            }
            film = film ?? ScenarioFilm()
            film?.margin = value
        }
        if let without { film = try film?.without(without) }
        return film
    }

    /// The film without the cards `value` names: "intro", "outro", or both separated by a comma, as
    /// `--scenario-without` gives them, so one scenario can be recorded without its titles. The backdrop stays.
    public func without(_ value: String) throws -> ScenarioFilm {
        var film = self
        for card in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch card {
            case "intro": film.intro = nil
            case "outro": film.outro = nil
            default: throw ScenarioError("\(card) is not a title card; leave out intro, outro or both.")
            }
        }
        return film
    }

    /// `media` finds a picture or video the film names, and throws when it is missing.
    public func validate(media: (String) throws -> URL) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ScenarioError(message) }
        }
        if let backdrop = self.media { _ = try media(backdrop) }
        for (label, text) in [("intro.kicker", intro?.kicker), ("intro.title", intro?.title),
                              ("intro.subtitle", intro?.subtitle), ("outro.tagline", outro?.tagline)] {
            try require(text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true, "film.\(label) has no text.")
        }
        try require((intro?.hold ?? 0) >= 0 && (outro?.hold ?? 0) >= 0, "A film holds for a negative time.")
        if let icon = intro?.icon { _ = try media(icon) }
        try require(Self.tints.contains(intro?.iconTint ?? "none"), "film.intro.iconTint is white or black.")
    }
}
#endif
