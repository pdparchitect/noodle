import Foundation
import Observation

/// A space the person made: bots and groups from any Hub, and on a Mac its own, with pins of its own.
public struct CustomSpace: Identifiable, Codable, Hashable, Sendable {
    /// A bot's or group's conversation as every device names it: on a Hub, by the Hub's key and the conversation
    /// there; with no Hub, by its ID on the one Mac that has it.
    public struct Member: Codable, Hashable, Sendable {
        public var hub: String?
        public var conversation: UUID

        public init(hub: String?, conversation: UUID) {
            self.hub = hub
            self.conversation = conversation
        }
    }

    public let id: UUID
    public var name: String
    /// Kept while out of reach, such as on a Hub that was left, so they come back with it.
    public var members: [Member]
    /// In the order they were pinned.
    public var pins: [Member]

    public init(id: UUID = UUID(), name: String, members: [Member] = [], pins: [Member] = []) {
        self.id = id
        self.name = name
        self.members = members
        self.pins = pins
    }
}

/// The spaces the person made, kept on this device in one file, by name.
@MainActor @Observable public final class SpaceList {
    public private(set) var spaces: [CustomSpace] = []
    @ObservationIgnored private let file: URL
    /// Each edit made here: the spaces saved and those deleted, for iCloud to carry to the person's other devices.
    @ObservationIgnored public var onChange: ((_ saved: [UUID], _ deleted: [UUID]) -> Void)?

    private struct Stored: Codable {
        var version = 1
        var spaces: [CustomSpace]
    }

    public init(file: URL) {
        self.file = file
        reload()
    }

    public func reload() {
        spaces = Self.ordered((try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: file)).spaces) ?? [])
    }

    /// What the person's other devices changed, kept without being handed on again.
    public func applyRemote(saved: [CustomSpace], deleted: [UUID]) {
        let replaced = Set(saved.map(\.id)).union(deleted)
        try? write(spaces.filter { !replaced.contains($0.id) } + saved)
    }

    public func space(_ id: UUID) -> CustomSpace? { spaces.first { $0.id == id } }

    @discardableResult
    public func add(named name: String) throws -> CustomSpace {
        let space = CustomSpace(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        try write(spaces + [space])
        onChange?([space.id], [])
        return space
    }

    public func rename(_ id: UUID, to name: String) throws {
        try update(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Only the space goes; its bots and groups stay where they are.
    public func delete(_ id: UUID) throws {
        try write(spaces.filter { $0.id != id })
        onChange?([], [id])
    }

    /// Leaving a space also drops the pin there.
    public func setMember(_ isMember: Bool, _ member: CustomSpace.Member, of id: UUID) throws {
        try update(id) { space in
            if isMember {
                if !space.members.contains(member) { space.members.append(member) }
            } else {
                space.members.removeAll { $0 == member }
                space.pins.removeAll { $0 == member }
            }
        }
    }

    public func setPinned(_ pinned: Bool, _ member: CustomSpace.Member, in id: UUID) throws {
        try update(id) { space in
            space.pins.removeAll { $0 == member }
            if pinned, space.members.contains(member) { space.pins.append(member) }
        }
    }

    private func update(_ id: UUID, _ change: (inout CustomSpace) -> Void) throws {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        var updated = spaces
        change(&updated[index])
        guard updated[index] != spaces[index] else { return }
        try write(updated)
        onChange?([id], [])
    }

    private func write(_ updated: [CustomSpace]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Stored(spaces: updated)).write(to: file, options: .atomic)
        spaces = Self.ordered(updated)
    }

    private static func ordered(_ spaces: [CustomSpace]) -> [CustomSpace] {
        spaces.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}
