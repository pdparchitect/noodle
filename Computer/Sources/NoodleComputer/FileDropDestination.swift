import Foundation

/// Shared by icon and list views so highlighting, cursor feedback and execution agree.
enum FileDropDestination {
    static func folder(_ current: String, hovered: GuestFile?, moving: [GuestFile] = []) -> String? {
        guard let hovered else { return moving.isEmpty ? current : nil }
        guard hovered.directory, !moving.contains(where: { $0.name == hovered.name }) else { return nil }
        return try? GuestFile.path(current, hovered.name)
    }
}
