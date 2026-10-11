import Foundation

/// Resolves the person's chosen decision model once and re-resolves when the
/// choice changes or a call fails, so settings changes and expiring keys take
/// effect without a restart. This is the single fail-open point: a nil here
/// means the caller keeps its unverified behavior, never an error.
public actor DecisionModelServingCache {
    private let store: DecisionModelChoiceStore
    private let accounts: RemoteModelAccountStore
    private var serving: (any DecisionModelServing)?
    private var choice: DecisionModelChoice?
    private var resolutionFailedAt: Date?

    /// How long a failed resolution keeps the cache offline before one retry.
    /// Bounds a broken provider to one resolution attempt per window (catalog
    /// fetch plus endpoint probes carry 30–60s timeouts) instead of one per
    /// tool call.
    private static let retryDelay: TimeInterval = 60

    public init(root: URL) {
        store = DecisionModelChoiceStore(repository: root)
        accounts = RemoteModelAccountStore(repository: root)
    }

    /// Runs `body` against the resolved serving. Returns nil — never throws —
    /// when no model is chosen, none can be reached, or the call fails; a
    /// failed call drops the cached serving so the next call re-resolves
    /// (after the retry window).
    public func call<T: Sendable>(_ body: @escaping @Sendable (any DecisionModelServing) async throws -> T?) async -> T? {
        guard let serving = await resolved() else { return nil }
        do { return try await body(serving) }
        catch {
            self.serving = nil
            resolutionFailedAt = Date()
            return nil
        }
    }

    private func resolved() async -> (any DecisionModelServing)? {
        let current = store.load()
        if serving == nil || choice != current {
            // A choice change resolves immediately; an unchanged choice whose
            // resolution recently failed stays offline for the retry window.
            if choice == current, serving == nil,
                let failedAt = resolutionFailedAt,
                Date().timeIntervalSince(failedAt) < Self.retryDelay {
                return nil
            }
            choice = current
            guard let current else { serving = nil; return nil }
            do {
                serving = try await DecisionModelResolver.serving(current, accounts: accounts)
                resolutionFailedAt = nil
            } catch {
                serving = nil
                resolutionFailedAt = Date()
                return nil
            }
        }
        return serving
    }
}
