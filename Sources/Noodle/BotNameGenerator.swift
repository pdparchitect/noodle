import Foundation

enum BotNameStyle: String, CaseIterable, Identifiable {
    case real
    case playful

    static let defaultsKey = "BotNameStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .real: "Real names"
        case .playful: "Playful names"
        }
    }
}

enum BotNameGenerator {
    private static let realNames = [
        "Ada", "Adrian", "Aisha", "Alex", "Alice", "Amara", "Amelia", "Amir",
        "Ana", "Andre", "Anika", "Anna", "Ari", "Arthur", "Ava", "Ben",
        "Blake", "Bruno", "Camille", "Carmen", "Cass", "Celia", "Charlie", "Chloe",
        "Clara", "Daniel", "Daria", "David", "Diego", "Eli", "Elena", "Elias",
        "Elise", "Emil", "Emma", "Eva", "Felix", "Finn", "Freya", "Gabriel",
        "Grace", "Hana", "Harper", "Hazel", "Hugo", "Iris", "Isaac", "Isla",
        "Ivan", "Jade", "James", "Jamie", "Jasper", "Jonah", "Jordan", "Julia",
        "Kai", "Kira", "Lara", "Leo", "Leona", "Levi", "Lina", "Luca",
        "Lucy", "Mae", "Mara", "Marco", "Maya", "Mia", "Mika", "Mila",
        "Milo", "Mina", "Nadia", "Naomi", "Nico", "Nina", "Noah", "Nora",
        "Omar", "Opal", "Oscar", "Owen", "Priya", "Quinn", "Ravi", "Remy",
        "Riley", "Robin", "Rosa", "Rowan", "Ruby", "Sam", "Sara", "Sasha",
        "Silas", "Sofia", "Sonia", "Theo", "Tobias", "Uma", "Vera", "Victor",
        "Violet", "Will", "Yara", "Yuki", "Zara", "Zoe"
    ]

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

    static func random(style: BotNameStyle, excluding current: String? = nil) -> String {
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
}
