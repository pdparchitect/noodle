import SwiftUI

/// What a companion app's window lists: this Mac's own items, or those Noodle Hub keeps for its bots.
public enum CompanionSpace: String, Sendable {
    case personal, hub
    public static let key = "Space"

    /// The space to show; Hub only while the Hub keeps something here.
    public func shown(hasHub: Bool) -> CompanionSpace { hasHub ? self : .personal }
}

/// The Spaces menu: Personal on ⌘1, Hub on ⌘2. Nothing to choose until the Hub keeps something here.
public struct CompanionSpaceCommands: Commands {
    @AppStorage(CompanionSpace.key) private var space = CompanionSpace.personal
    private let hasHub: Bool
    public init(hasHub: Bool) { self.hasHub = hasHub }

    public var body: some Commands {
        if hasHub {
            CommandMenu("Spaces") {
                Toggle("Personal", isOn: Binding(get: { space == .personal }, set: { if $0 { space = .personal } }))
                    .keyboardShortcut("1")
                Toggle("Hub", isOn: Binding(get: { space == .hub }, set: { if $0 { space = .hub } }))
                    .keyboardShortcut("2")
            }
        }
    }
}
