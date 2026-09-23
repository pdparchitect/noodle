import Foundation

@MainActor public protocol RuntimeStopConnection: AnyObject {
    func stop(reply: @escaping (Bool) -> Void)
}

/// A failed stop must keep its transport: absence of a connection is not proof
/// that its runtime exited. All callers share one outstanding confirmation.
@MainActor public final class RuntimeShutdown {
    private var connection: (any RuntimeStopConnection)?
    private var attempt: UUID?
    private var completions: [(Bool) -> Void] = []

    var isPending: Bool { connection != nil }

    func stop(_ connection: (any RuntimeStopConnection)?, completion: @escaping (Bool) -> Void) {
        if let connection { self.connection = connection }
        guard let connection = self.connection else { completion(true); return }
        completions.append(completion)
        guard attempt == nil else { return }
        let id = UUID()
        attempt = id
        connection.stop { [self] stopped in
            Task { @MainActor in
                guard attempt == id else { return }
                attempt = nil
                if stopped { self.connection = nil }
                let replies = completions
                completions = []
                replies.forEach { $0(stopped) }
            }
        }
    }
}
