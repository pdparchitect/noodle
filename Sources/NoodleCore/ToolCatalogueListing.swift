import Foundation

/// One entry of the app's tool catalogue as a bot may read it, so it can tell whether the app could do something, who it
/// could ask, or what to suggest the person turn on. It says only how far the entry is set up and given out, as seen by
/// the bot asking: never whose account it is, how it is set up, or which bots it does not share a conversation with have it.
public struct ToolCatalogueListing: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The app offers it and no one has added it here.
        case available
        /// At least one connection was made from it, signed in or not, but no bot has one.
        case configured
        /// Other bots have a connection made from it; the asking bot does not.
        case assigned
        /// The asking bot has a connection made from it.
        case assignedToYou = "assigned to you"
    }

    /// Another bot with a connection from this entry, named only because it shares a conversation with the asking bot.
    public struct Assignee: Codable, Equatable, Sendable {
        public let name: String
        public let agentID: UUID
        public init(name: String, agentID: UUID) { self.name = name; self.agentID = agentID }
    }

    public let name: String
    public let summary: String
    public let status: Status
    /// The other bots with it that the asking bot shares a conversation with, by name; nil when there are none.
    public let assignedTo: [Assignee]?
    /// True when bots the asking bot shares no conversation with have it too; nil otherwise. Never how many.
    public let alsoAssignedElsewhere: Bool?

    public init(name: String, summary: String, status: Status, assignedTo: [Assignee]? = nil, alsoAssignedElsewhere: Bool? = nil) {
        self.name = name; self.summary = summary; self.status = status
        self.assignedTo = assignedTo; self.alsoAssignedElsewhere = alsoAssignedElsewhere
    }

    /// One row per entry of `entries`, by name, however many connections were made from it, as `requester` sees it.
    /// `bots` names the bots whose grants count: an assignment to any other, such as a deleted or archived bot, does not.
    /// `known` holds the bots `requester` shares a conversation with, the only ones it may be told of.
    public static func rows(entries: [ToolDefinition], registry: ToolConnectionRegistry, requester: UUID,
                            bots: [UUID: String], known: Set<UUID>) -> [Self] {
        var entryByConnection: [UUID: String] = [:]
        for connection in registry.connections {
            entryByConnection[connection.id] = entry(madeFrom: connection, in: entries)?.id
        }
        var holders: [String: Set<UUID>] = [:]
        for (key, ids) in registry.assignments {
            guard let bot = UUID(uuidString: key), bots[bot] != nil else { continue }
            for id in ids { if let entry = entryByConnection[id] { holders[entry, default: []].insert(bot) } }
        }
        let configured = Set(entryByConnection.values)
        return entries
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { entry in
                let have = holders[entry.id] ?? []
                let others = have.subtracting([requester])
                let named = others.intersection(known).compactMap { id in bots[id].map { Assignee(name: $0, agentID: id) } }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let status: Status = have.contains(requester) ? .assignedToYou
                    : !others.isEmpty ? .assigned : configured.contains(entry.id) ? .configured : .available
                return .init(name: entry.name, summary: entry.summary, status: status,
                             assignedTo: named.isEmpty ? nil : named,
                             alsoAssignedElsewhere: others.subtracting(known).isEmpty ? nil : true)
            }
    }

    /// The entry `connection` remembers it was made from, if it is still at an address that entry makes. Unlike
    /// `ToolCatalog.definition(for:)`, one without a remembered entry, as one added by address, counts for none, even at
    /// a preset's address.
    private static func entry(madeFrom connection: ToolConnection, in entries: [ToolDefinition]) -> ToolDefinition? {
        guard let id = connection.catalogueID, let entry = entries.first(where: { $0.id == id }) else { return nil }
        switch entry.configuration {
        case .connection(let configuration):
            return (try? configuration.account(connection.settings ?? [:]).endpoint) == connection.endpoint ? entry : nil
        }
    }

    /// The running app's catalogue against the connections saved in `repository`, as `agentID` sees it: the bots it
    /// knows are those it shares a current conversation with, as `--list-participants` shows them.
    public static func rows(repository: WorkspaceRepository, agentID: UUID) throws -> [Self] {
        let registry: ToolConnectionRegistry
        do { registry = try ToolConnectionRegistry.load(root: repository.rootURL) } catch {
            throw ToolConnectionError.message("The tool connections could not be read, so which tools are set up is unknown.")
        }
        let agents = try repository.loadAgents()
        guard agents.contains(where: { $0.id == agentID }) else { throw WorkspaceError.missingAgent(agentID) }
        // An archived bot never runs, so it has nothing and is no one to ask.
        let bots = Dictionary(agents.filter { $0.archivedAt == nil || $0.id == agentID }.map { ($0.id, $0.displayName) },
                              uniquingKeysWith: { first, _ in first })
        let known = Set(try repository.loadConversations()
            .filter { $0.archivedAt == nil && $0.participantIDs.contains(agentID) }
            .flatMap(\.participantIDs))
        return rows(entries: ToolCatalog.entries, registry: registry, requester: agentID, bots: bots, known: known)
    }
}
