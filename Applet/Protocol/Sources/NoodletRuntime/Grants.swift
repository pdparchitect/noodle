import Foundation
import NoodletFormat

/// What the person on this device allowed noodlets from a Noodle Hub: asked once per noodlet for
/// everything its manifest declares, and kept until they take it back.
public struct NoodletGrants: @unchecked Sendable {
    public struct Grant: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var title: String
        public var permissions: [String]
    }

    private static let key = "noodletGrants"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// By title.
    public var all: [Grant] {
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Grant].self, from: $0) } ?? []
        return stored.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Whether `manifest` declares anything not yet allowed for the noodlet `id`.
    public func needsAsking(_ manifest: NoodletManifest, id: UUID) -> Bool {
        let allowed = Set(all.first { $0.id == id }?.permissions ?? [])
        return !Set(manifest.permissions ?? []).isSubset(of: allowed)
    }

    public func allow(_ manifest: NoodletManifest, id: UUID) {
        save(all.filter { $0.id != id } + [Grant(id: id, title: manifest.title, permissions: (manifest.permissions ?? []).sorted())])
    }

    public func revoke(_ id: UUID) { save(all.filter { $0.id != id }) }

    private func save(_ grants: [Grant]) {
        defaults.set(try? JSONEncoder().encode(grants), forKey: Self.key)
    }

    /// What the person is asked before the noodlet starts.
    public static func question(_ manifest: NoodletManifest) -> String {
        "“\(manifest.title)” would like to use \(names(manifest))."
    }

    /// Why the noodlet did not start, when the person said no.
    public static func refusal(_ manifest: NoodletManifest) -> String {
        "Permission was not given to use \(names(manifest))."
    }

    private static func names(_ manifest: NoodletManifest) -> String {
        (manifest.permissions ?? []).sorted().compactMap { NoodletManifest.permissionNames[$0] }.joined(separator: " and ")
    }
}
