import Foundation
@main struct StartupTest {
    @MainActor static func main() async throws {
        let first = WindowsGraphicsStartup(), second = WindowsGraphicsStartup()
        let result = try await first.check { allowed in
            precondition(allowed)
            return true
        }
        guard result == .restart else { print("FAIL: driver staging must request a restart"); exit(1) }
        let ready = try await first.check { allowed in
            precondition(!allowed, "A failed installation must not loop")
            return false
        }
        precondition(ready == .ready)
        let independent = try await second.check { allowed in
            precondition(allowed, "Another VM has independent setup state")
            return true
        }
        precondition(independent == .restart)
        let cycle = WindowsPowerCycle(), otherCycle = WindowsPowerCycle()
        var stoppedDuringRestart = false, started = false
        try await cycle.run(stop: {
            stoppedDuringRestart = cycle.handlesGuestStop(machineStopped: true)
            precondition(otherCycle.handlesGuestStop(machineStopped: true), "Another VM can shut down during this restart")
        }, start: { started = true })
        guard !stoppedDuringRestart, started else { print("FAIL: planned restart must not report a final VM stop"); exit(1) }
        precondition(!cycle.handlesGuestStop(machineStopped: false), "Ignore a late stop callback once the VM is running again")
        precondition(cycle.handlesGuestStop(machineStopped: true), "A later genuine shutdown must finish the VM")
        print("PASS: driver restart, verification, independent VM setup")
    }
}
