import Combine
import Foundation

/// A browser or computer the caller made, or one a person lent it.
public struct ExternalResource: Codable, Hashable, Sendable {
    public var id: UUID
    public var created: Bool
}

/// An app a person allowed to use external tools, and what it may use.
public struct ExternalCaller: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var launcher: ExternalLauncher
    public var approvedAt: Date
    public var resources: [ExternalResource]
}

public struct ExternalGrants: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    public var callers: [ExternalCaller] = []
    public init() {}
}

/// Something a caller may be lent.
public struct ExternalItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public init(id: UUID, name: String, symbol: String = "circle") { self.id = id; self.name = name; self.symbol = symbol }
}

/// Asks the person. Each answers false or nil when they decline or do not answer.
@MainActor public protocol ExternalPrompting: AnyObject {
    func approve(_ launcher: ExternalLauncher) async -> Bool
    func pick(_ launcher: ExternalLauncher, from items: [ExternalItem]) async -> UUID?
    func confirm(_ launcher: ExternalLauncher, message: String, action: String) async -> Bool
}

/// Decides what callers outside Noodle may do, asking the person where needed, and remembers
/// their answers. The app enforces it on every call that comes over its external connection.
@MainActor public final class ExternalGate: ObservableObject {
    @Published public private(set) var grants = ExternalGrants()
    @Published public private(set) var failure: String?
    public weak var prompter: ExternalPrompting?
    /// Called after the master switch changes, to start or stop listening.
    public var enabledChanged: ((Bool) -> Void)?
    /// Called with a caller and the items it can no longer use, so the app can end its sessions on them.
    public var revoked: ((UUID, [UUID]) -> Void)?
    private let url: URL?
    private var readable = true
    private var refused: [String: Date] = [:]
    private var asking: [String: Task<Bool, Never>] = [:]
    private var questioning: Set<UUID> = []
    /// How long a caller someone refused is turned away without asking again.
    static let quietPeriod: TimeInterval = 300

    public init(url: URL?, prompter: ExternalPrompting?) {
        self.url = url; self.prompter = prompter
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let grants = try JSONDecoder().decode(ExternalGrants.self, from: data)
            guard grants.version == 1 else { throw ExternalToolsError("Unsupported external tools file.") }
            self.grants = grants
        } catch {
            readable = false
            failure = "Could not read the external tools settings, so external tools are off. Existing data was not changed."
        }
    }

    public var enabled: Bool {
        get { grants.enabled }
        set {
            guard newValue != grants.enabled, readable else { return }
            update { $0.enabled = newValue }
            enabledChanged?(newValue)
            // Off means off: sessions apps already opened end too.
            if !grants.enabled {
                for caller in grants.callers where !caller.resources.isEmpty { revoked?(caller.id, caller.resources.map(\.id)) }
            }
        }
    }

    public func caller(_ id: UUID) -> ExternalCaller? { grants.callers.first { $0.id == id } }
    public func allows(_ caller: UUID, _ resource: UUID) -> Bool { self.caller(caller)?.resources.contains { $0.id == resource } == true }
    public func created(_ caller: UUID, _ resource: UUID) -> Bool { self.caller(caller)?.resources.contains { $0.id == resource && $0.created } == true }
    public func createdCount(_ caller: UUID) -> Int { self.caller(caller)?.resources.filter(\.created).count ?? 0 }
    /// Who made a resource, if a caller did.
    public func creator(of resource: UUID) -> ExternalCaller? {
        grants.callers.first { $0.resources.contains { $0.id == resource && $0.created } }
    }

    /// The remembered caller, asking the person the first time. Calls that arrive while the
    /// question is open wait for the same answer.
    public func admit(_ launcher: ExternalLauncher) async throws -> ExternalCaller {
        guard enabled else { throw ExternalToolsError("External tools are turned off in Settings.") }
        if let index = grants.callers.firstIndex(where: { $0.launcher.key == launcher.key }) {
            if grants.callers[index].launcher != launcher { update { $0.callers[index].launcher = launcher } }
            return grants.callers[index]
        }
        if let when = refused[launcher.key], Date().timeIntervalSince(when) < Self.quietPeriod {
            throw ExternalToolsError("\(launcher.name) was not allowed to use this app.")
        }
        let question = asking[launcher.key] ?? Task { [prompter] in await prompter?.approve(launcher) ?? false }
        asking[launcher.key] = question
        let approved = await question.value
        asking[launcher.key] = nil
        if let existing = grants.callers.first(where: { $0.launcher.key == launcher.key }) { return existing }
        guard approved, enabled else {
            refused[launcher.key] = Date()
            throw ExternalToolsError("\(launcher.name) was not allowed to use this app.")
        }
        let caller = ExternalCaller(id: UUID(), launcher: launcher, approvedAt: Date(), resources: [])
        update { $0.callers.append(caller) }
        return caller
    }

    /// Asks the person which item to lend; the caller is never shown the rest.
    public func borrow(for caller: UUID, from items: [ExternalItem]) async throws -> UUID {
        let offered = items.filter { !allows(caller, $0.id) }
        guard !offered.isEmpty else { throw ExternalToolsError("There is nothing else to lend.") }
        let picked = try await question(caller, "borrow", declined: "Nothing was lent.") { prompter, launcher in
            await prompter.pick(launcher, from: offered).flatMap { picked in offered.contains { $0.id == picked } ? picked : nil }
        }
        setAccess(true, to: picked, for: caller)
        return picked
    }

    public func confirm(for caller: UUID, message: String, action: String) async throws {
        _ = try await question(caller, "confirm", declined: "The request was declined.") { prompter, launcher in
            await prompter.confirm(launcher, message: message, action: action) ? true : nil
        }
    }

    /// One question to the person at a time per caller, and none of a kind they just declined, so an
    /// app cannot bury them in questions.
    private func question<Answer>(_ caller: UUID, _ kind: String, declined: String,
                                  _ ask: @MainActor (ExternalPrompting, ExternalLauncher) async -> Answer?) async throws -> Answer {
        guard let launcher = self.caller(caller)?.launcher, let prompter else { throw ExternalToolsError("This app's access was removed.") }
        guard !questioning.contains(caller) else { throw ExternalToolsError("The person has not answered this app's last question yet.") }
        let key = "\(caller)/\(kind)"
        if let when = refused[key], Date().timeIntervalSince(when) < Self.quietPeriod { throw ExternalToolsError(declined) }
        questioning.insert(caller)
        let answer = await ask(prompter, launcher)
        questioning.remove(caller)
        guard let answer, self.caller(caller) != nil else {
            refused[key] = Date()
            throw ExternalToolsError(declined)
        }
        return answer
    }

    public func require(_ caller: UUID, _ resource: UUID) throws {
        guard allows(caller, resource) else { throw ExternalToolsError("This app has no access to that. Create one, or borrow one.") }
    }

    public func recordCreated(_ resource: UUID, by caller: UUID) {
        update { grants in
            guard let index = grants.callers.firstIndex(where: { $0.id == caller }) else { return }
            grants.callers[index].resources.removeAll { $0.id == resource }
            grants.callers[index].resources.append(.init(id: resource, created: true))
        }
    }

    /// A switch in Settings, or a loan. Turning one off keeps nothing about it.
    public func setAccess(_ allowed: Bool, to resource: UUID, for caller: UUID) {
        let lost = !allowed && allows(caller, resource)
        defer { if lost, !allows(caller, resource) { revoked?(caller, [resource]) } }
        update { grants in
            guard let index = grants.callers.firstIndex(where: { $0.id == caller }) else { return }
            let had = grants.callers[index].resources.contains { $0.id == resource }
            if allowed, !had { grants.callers[index].resources.append(.init(id: resource, created: false)) }
            if !allowed { grants.callers[index].resources.removeAll { $0.id == resource } }
        }
    }

    /// Forgets the caller; it is asked about again next time. Returns what it was.
    @discardableResult public func remove(_ caller: UUID) -> ExternalCaller? {
        let removed = self.caller(caller)
        update { $0.callers.removeAll { $0.id == caller } }
        if let removed, self.caller(caller) == nil, !removed.resources.isEmpty { revoked?(caller, removed.resources.map(\.id)) }
        return removed
    }

    /// The resource is gone.
    public func forget(_ resource: UUID) {
        guard grants.callers.contains(where: { $0.resources.contains { $0.id == resource } }) else { return }
        update { grants in for index in grants.callers.indices { grants.callers[index].resources.removeAll { $0.id == resource } } }
    }

    /// Forgets every resource that no longer exists.
    public func prune(keeping existing: Set<UUID>) {
        guard grants.callers.contains(where: { $0.resources.contains { !existing.contains($0.id) } }) else { return }
        update { grants in for index in grants.callers.indices { grants.callers[index].resources.removeAll { !existing.contains($0.id) } } }
    }

    private func update(_ change: (inout ExternalGrants) -> Void) {
        guard readable else { return }
        var next = grants
        change(&next)
        guard next != grants else { return }
        if let url {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            } catch { failure = "Could not save the external tools settings. \(error.localizedDescription)"; return }
        }
        grants = next
    }
}
