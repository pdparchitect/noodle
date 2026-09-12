import Foundation

/// Shared by icon and list views so highlighting, cursor feedback and execution agree.
enum FileDropDestination {
    static func folder(_ current: String, hovered: GuestFile?, moving: GuestFile? = nil) -> String? {
        guard let hovered else { return moving == nil ? current : nil }
        guard hovered.directory, hovered.name != moving?.name else { return nil }
        return try? GuestFile.path(current, hovered.name)
    }
}
