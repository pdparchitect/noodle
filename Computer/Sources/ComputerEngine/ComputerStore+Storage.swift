import ComputerCore
import Foundation

extension ComputerStore {
    public var storageOperationsBusy: Bool {
        creationStatus != nil || !imageUpdateTasks.isEmpty || sessions.contains { $0.phase.busy }
    }

    public func inspectStorage() {
        guard !storageBusy else { return }
        guard !storageOperationsBusy else {
            storageError = "Wait for computer creation, startup or updates to finish, then refresh Storage."
            return
        }
        storageBusy = true
        storageError = nil
        Task {
            defer { storageBusy = false }
            do { storageReport = try await StorageMaintenance.inspect(library: library) }
            catch { storageReport = nil; storageError = error.localizedDescription }
        }
    }

    /// Computers whose disks Free Up Space can only reach by stopping them.
    public var storageRunningSessions: [ComputerSession] {
        sessions.filter { $0.container != nil || $0.virtual != nil }
    }

    /// Without `stopRunning`, running computers keep going and their disks are left alone.
    public func cleanStorage(preview: StorageReport, stopRunning: Bool = true) {
        guard !storageBusy, !storageOperationsBusy else {
            storageError = "Wait for computer creation, startup or updates to finish, then refresh Storage."
            return
        }
        storageBusy = true
        storageCleaning = true
        storageError = nil
        storageTask = Task {
            defer { storageBusy = false; storageCleaning = false; storageProgress = nil; storageTask = nil }
            let running = stopRunning ? sessions.filter { $0.phase == .running } : []
            let skipping = stopRunning ? [] : Set(storageRunningSessions.map(\.computer.id))
            do {
                if stopRunning {
                    for session in storageRunningSessions {
                        storageProgress = ("Stopping \(session.computer.name)…", 0)
                        await stopComputer(session, force: true)
                    }
                    guard storageRunningSessions.isEmpty else {
                        throw ComputerError("A computer could not stop. Nothing was removed. Stop it and try again.")
                    }
                }
                storageError = try await StorageMaintenance.clean(library: library, preview: preview, skipping: skipping) { label, fraction in
                    await MainActor.run { self.storageProgress = (label, fraction) }
                }
            } catch { storageError = error.localizedDescription }
            // Restore the previously running set even if cleanup failed. Quitting
            // cancels maintenance, so it must never start guests again on shutdown.
            for session in running where session.container == nil && session.virtual == nil && !Task.isCancelled {
                storageProgress = ("Restarting \(session.computer.name)…", 1)
                await startComputer(session)
                if session.phase != .running {
                    storageError = (storageError ?? "") + "\n\(session.computer.name) could not restart: \(session.phase.label). Check the computer’s console."
                }
            }
            do { storageReport = try await StorageMaintenance.inspect(library: library) }
            catch { storageReport = nil; storageError = (storageError ?? "") + "\n" + error.localizedDescription }
        }
    }
}
