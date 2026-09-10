import ComputerCore
import Foundation

extension ComputerStore {
    var storageOperationsBusy: Bool {
        creationStatus != nil || !imageUpdateTasks.isEmpty || sessions.contains { $0.phase.busy }
    }

    func inspectStorage() {
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

    func cleanStorage(preview: StorageReport) {
        guard !storageBusy, !storageOperationsBusy else {
            storageError = "Wait for computer creation, startup or updates to finish, then refresh Storage."
            return
        }
        storageBusy = true
        storageCleaning = true
        storageError = nil
        storageTask = Task {
            defer { storageBusy = false; storageCleaning = false; storageTask = nil }
            let running = sessions.filter { $0.phase == .running }
            do {
                for session in sessions where session.container != nil || session.virtual != nil {
                    await stopComputer(session, force: true)
                }
                guard sessions.allSatisfy({ $0.container == nil && $0.virtual == nil }) else {
                    throw ComputerError("A computer could not stop. No caches were removed. Stop it and try again.")
                }
                storageError = try await StorageMaintenance.clean(library: library, preview: preview)
            } catch { storageError = error.localizedDescription }
            // Restore the previously running set even if cleanup failed. Quitting
            // cancels maintenance, so it must never start guests again on shutdown.
            for session in running where session.container == nil && session.virtual == nil && !Task.isCancelled {
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
