import Foundation
import NoodleCore
import ProductIdentity

/// What the Share extension and the Services menu leave in the app group, in every app: the conversations they
/// may send to, and the items they sent, delivered as the person's messages.
@MainActor public final class SharedInboxDelivery {
    private var isDelivering = false
    /// An item that could not be delivered waits until the app opens again, so its error is said once.
    private var failed: Set<UUID> = []

    public init() {}

    /// The conversations something can be sent to, by name, for the extension's picker.
    public static func publish(_ conversations: [BotConversation], to inbox: SharedInbox, title: (BotConversation) -> String) {
        try? inbox.saveDestinations(conversations.map {
            ShareDestination(id: $0.id, name: title($0), isGroup: $0.kind == .group)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// Sends each waiting item into its conversation, hands the message to `delivered`, and takes it from the inbox.
    public func deliver(from inbox: SharedInbox, repository: WorkspaceRepository, delivered: (ChatMessage) -> Void,
                        problem: (String) -> Void) async {
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        do {
            let pending = try await Task.detached { try inbox.pending() }.value
            for request in pending where !failed.contains(request.id) {
                do {
                    let message = try await Task.detached {
                        try repository.sendSharedMessage(request, files: inbox.files(for: request))
                    }.value
                    delivered(message)
                    try await Task.detached { try inbox.acknowledge(request.id) }.value
                } catch {
                    failed.insert(request.id)
                    problem("Could not deliver a shared item: \(error.localizedDescription) The item is retained for retry when \(ProductIdentity.current.name) restarts.")
                }
            }
        } catch { problem("Could not read shared items: \(error.localizedDescription)") }
    }
}
