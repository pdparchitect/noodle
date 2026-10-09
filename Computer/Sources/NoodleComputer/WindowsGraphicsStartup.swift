/// Per-computer setup state survives its driver restart, but never leaks into another VM.
@MainActor final class WindowsGraphicsStartup {
    enum Action: Equatable { case ready, restart, busy }
    private var checking = false
    private var staged = false
    func check(prepare: (Bool) async throws -> Bool) async throws -> Action {
        guard !checking else { return .busy }
        checking = true
        defer { checking = false }
        let restart = try await prepare(!staged)
        if restart { staged = true }
        return restart ? .restart : .ready
    }
}

/// VZ can deliver the stop callback during, or just after, a requested stop/start cycle.
@MainActor final class WindowsPowerCycle {
    private(set) var running = false
    func run(stop: () async throws -> Void, start: () async throws -> Void) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        try await stop()
        try await start()
    }
    func handlesGuestStop(machineStopped: Bool) -> Bool { !running && machineStopped }
}
