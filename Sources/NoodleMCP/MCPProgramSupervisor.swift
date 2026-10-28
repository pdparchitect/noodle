import Foundation
import NoodleCore

/// One process per program. Restarts stay inside the recorded back-off, then the program stays failed.
public actor MCPProgramSupervisor {
    private struct Slot {
        var session: MCPProgramSession?
        var life = MCPProgramRecord.Lifecycle()
        var launch: (@Sendable () throws -> MCPProgramSession)?
        var message: String?
    }

    public init() {}
    private var slots: [UUID: Slot] = [:]
    /// Test seam. Production uses the recorded delays.
    public var pause: (@Sendable (Int) -> TimeInterval)?

    public func prepare(_ id: UUID, launch: @escaping @Sendable () throws -> MCPProgramSession) {
        var slot = slots[id] ?? Slot()
        slot.launch = launch
        slots[id] = slot
    }

    public func standardError(_ id: UUID) -> String? { slots[id]?.session?.standardError() }

    public func failureMessage(_ id: UUID) -> String? { slots[id]?.message }

    public func isRunning(_ id: UUID) -> Bool { slots[id]?.session?.isRunning == true }

    public func noteUse(_ id: UUID, at date: Date) {
        slots[id]?.life.used(at: date)
    }

    public func stop(_ id: UUID) {
        slots[id]?.session?.stop()
        slots[id]?.session = nil
        slots[id]?.life = MCPProgramRecord.Lifecycle()
        slots[id]?.launch = nil
    }

    public func stopAll() {
        for id in Array(slots.keys) {
            slots[id]?.session?.stop()
            slots[id]?.session = nil
            slots[id]?.life.stopped()
        }
    }

    public func stopIfIdle(_ id: UUID, at now: Date) {
        guard slots[id]?.life.isIdle(at: now) == true else { return }
        slots[id]?.session?.stop()
        slots[id]?.session = nil
        slots[id]?.life = MCPProgramRecord.Lifecycle()
    }

    public func start(_ id: UUID) async throws -> MCPProgramSession {
        guard var slot = slots[id], let launch = slot.launch else {
            throw MCPConnectionError.message("This program is no longer connected.")
        }
        if slot.life.failed {
            throw MCPConnectionError.message(slot.message ?? Self.failedText)
        }
        if let session = slot.session, session.isRunning {
            slot.life.used(at: Date())
            slots[id] = slot
            return session
        }
        let session = try launch()
        slot.session = session
        slot.life.started(at: Date())
        slots[id] = slot
        observe(id, session: session)
        return session
    }

    private func observe(_ id: UUID, session: MCPProgramSession) {
        let pid = session.processIdentifier
        Task {
            while session.isRunning { try? await Task.sleep(for: .milliseconds(40)) }
            await self.ended(id, pid: pid)
        }
    }

    private func ended(_ id: UUID, pid: Int32) async {
        guard var slot = slots[id], slot.session?.processIdentifier == pid else { return }
        if slot.session?.wasStopped == true {
            slot.session = nil
            slot.life.stopped()
            slots[id] = slot
            return
        }
        let delay = slot.life.crashed()
        slot.session = nil
        slots[id] = slot
        guard let delay, let launch = slot.launch else {
            slot.message = Self.failedText
            slots[id] = slot
            return
        }
        let seconds = pause?(slot.life.failures - 1) ?? delay
        try? await Task.sleep(for: .seconds(seconds))
        guard var again = slots[id], again.launch != nil, again.session == nil, !again.life.failed else { return }
        do {
            let next = try launch()
            again.session = next
            again.life.started(at: Date())
            slots[id] = again
            observe(id, session: next)
        } catch {
            again.message = error.localizedDescription
            slots[id] = again
        }
    }

    public static let failedText = "The program stopped after several crashes. It will stay disconnected until you try again."
}
