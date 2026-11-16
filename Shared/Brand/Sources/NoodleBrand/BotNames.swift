import Foundation

/// How new bots are named: a person's first name, or a playful pair of words.
public enum BotNameStyle: String, CaseIterable, Identifiable, Sendable {
    case real
    case playful

    public static let defaultsKey = "BotNameStyle"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .real: "Real"
        case .playful: "Playful"
        }
    }
}

public enum BotNameGenerator {
    // Who each name suits a face of: names worn by both go to any face.
    private static let feminineNames = [
        "Ada", "Aisha", "Alice", "Amara", "Amelia", "Ana", "Anika", "Anna",
        "Ava", "Camille", "Carmen", "Celia", "Chloe", "Clara", "Daria", "Elena",
        "Elise", "Emma", "Eva", "Freya", "Grace", "Hana", "Hazel", "Iris",
        "Isla", "Jade", "Julia", "Kira", "Lara", "Leona", "Lina", "Lucy",
        "Mae", "Mara", "Maya", "Mia", "Mila", "Mina", "Nadia", "Naomi",
        "Nina", "Nora", "Opal", "Priya", "Rosa", "Ruby", "Sara", "Sofia",
        "Sonia", "Uma", "Vera", "Violet", "Yara", "Zara", "Zoe"
    ]

    private static let masculineNames = [
        "Adrian", "Amir", "Andre", "Arthur", "Ben", "Bruno", "Daniel", "David",
        "Diego", "Eli", "Elias", "Emil", "Felix", "Finn", "Gabriel", "Hugo",
        "Isaac", "Ivan", "James", "Jasper", "Jonah", "Leo", "Levi", "Luca",
        "Marco", "Milo", "Nico", "Noah", "Omar", "Oscar", "Owen", "Ravi",
        "Silas", "Theo", "Tobias", "Victor", "Will"
    ]

    private static let eitherNames = [
        "Alex", "Ari", "Blake", "Cass", "Charlie", "Harper", "Jamie", "Jordan",
        "Kai", "Mika", "Quinn", "Remy", "Riley", "Robin", "Rowan", "Sam",
        "Sasha", "Yuki"
    ]

    static let realNames = feminineNames + masculineNames + eitherNames

    private static let descriptors = [
        "Amber", "Bright", "Brisk", "Calm", "Clever", "Copper", "Cozy", "Curious",
        "Daring", "Dusk", "Ember", "Gentle", "Golden", "Happy", "Indigo", "Jolly",
        "Keen", "Lucky", "Lunar", "Merry", "Mint", "Misty", "Nimble", "Quiet",
        "Sage", "Silver", "Sunny", "Swift", "Velvet", "Vivid", "Warm", "Wild"
    ]

    private static let companions = [
        "Badger", "Beacon", "Birch", "Comet", "Corgi", "Finch", "Fox", "Gecko",
        "Heron", "Juniper", "Kite", "Lark", "Lynx", "Maple", "Marlin", "Moth",
        "Otter", "Panda", "Pebble", "Pixel", "Quill", "Robin", "Sparrow", "Sprout",
        "Starling", "Thistle", "Tiger", "Willow", "Wren", "Yak", "Zinnia", "Zuzu"
    ]

    /// A name not among `taken`, whatever its case, nor `current`; when every name is taken, one with a number.
    public static func random(style: BotNameStyle, excluding current: String? = nil, avoiding taken: some Sequence<String>) -> String {
        let current = current?.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set((Array(taken) + [current].compactMap { $0 }).map { $0.lowercased() })
        for _ in 0..<64 {
            let candidate = random(style: style, excluding: current)
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        if style == .real, let name = realNames.shuffled().first(where: { !taken.contains($0.lowercased()) }) { return name }
        let base = random(style: style)
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    public static func random(style: BotNameStyle, excluding current: String? = nil) -> String {
        let current = current?.trimmingCharacters(in: .whitespacesAndNewlines)

        for _ in 0..<8 {
            let candidate: String
            switch style {
            case .real:
                candidate = realNames.randomElement() ?? "Alex"
            case .playful:
                guard let descriptor = descriptors.randomElement(),
                      let companion = companions.randomElement() else { return "Noodle" }
                candidate = "\(descriptor) \(companion)"
            }
            if candidate != current { return candidate }
        }

        return style == .real ? "Alex" : "Noodle"
    }

    /// Which faces suit a name this generator makes: `.some(nil)` for any face, nil for a name it does not know.
    public static func presentation(of name: String) -> BotFacePresentation?? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if known(feminineNames, name) { return .some(.feminine) }
        if known(masculineNames, name) { return .some(.masculine) }
        if known(eitherNames, name) { return .some(nil) }
        let words = name.split(separator: " ").map(String.init)
        if words.count == 2, known(descriptors, words[0]), known(companions, words[1]) { return .some(nil) }
        return nil
    }

    private static func known(_ names: [String], _ word: String) -> Bool {
        names.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}
