import ComputerCore
import Foundation

extension ComputerStore {
    func updateImage(_ session: ComputerSession) async {
        guard session.computer.kind == .container, !session.phase.busy,
              imageUpdateTasks[session.id] == nil else { return }
        error = nil
        session.updateResult = nil
        let task = Task { await self.performImageUpdate(session) }
        imageUpdateTasks[session.id] = task
        defer { imageUpdateTasks[session.id] = nil }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelImageUpdate(_ session: ComputerSession) {
        imageUpdateTasks[session.id]?.cancel()
    }

    private func performImageUpdate(_ session: ComputerSession) async {
        let directory = library.directory(for: session.id)
        let wasRunning = session.phase == .running
        var candidate: ContainerDiskState?
        var verifier: ContainerComputer?
        var committed = false
        defer { session.updateStatus = nil; session.updateProgress = nil }
        do {
            let previous = try ContainerDiskState.load(in: directory)
            if session.container != nil || session.virtual != nil { await stop(session, force: true) }
            guard session.container == nil, session.virtual == nil else {
                throw ComputerError("Stop this computer before updating its image.")
            }
            session.phase = .updating
            session.updateStatus = "Checking for a new image…"
            let computer = session.computer
            candidate = try await ContainerComputer.prepareImage(computer: computer, directory: directory,
                cache: cache, previous: previous) { text, progress in
                    await MainActor.run {
                        session.updateStatus = text
                        session.updateProgress = progress?.fraction
                    }
                }
            if let candidate {
                try Task.checkCancellation()
                session.updateStatus = "Checking that the updated computer starts…"
                session.updateProgress = nil
                let runtime = ContainerComputer()
                verifier = runtime
                _ = try await runtime.start(computer: computer, directory: directory, cache: cache,
                                            kernel: kernel, preparedState: candidate)
                let check = try await runtime.execute(ContainerComputer.overlayCheckCommand)
                guard check.contains("[Exit 0]") else { throw ComputerError("The updated writable filesystem did not start correctly.") }
                try await runtime.stop()
                verifier = nil
                try Task.checkCancellation()
                try candidate.activate(in: directory)
                committed = true
                // Retain one complete prior base/overlay pair for recovery. Never
                // delete either the active pair or the pair we just replaced.
                if let obsolete = previous.previousGeneration,
                   obsolete != previous.generation, obsolete != candidate.generation {
                    let old = directory.appendingPathComponent("Layers").appendingPathComponent(obsolete.uuidString.lowercased())
                    try? FileManager.default.removeItem(at: old)
                }
                session.append("\nUpdated the computer image. Your writable layer was preserved.\n")
                session.updateResult = "The computer image is up to date."
            } else {
                session.append("\nThe computer already has the current image.\n")
                session.updateResult = "The computer image is already up to date."
            }
            session.phase = .stopped
            if wasRunning && !Task.isCancelled { await start(session) }
        } catch {
            var candidateStopped = true
            if let verifier {
                do { try await verifier.stop() }
                catch { candidateStopped = false }
            }
            if !committed, candidateStopped, let candidate {
                try? FileManager.default.removeItem(at: candidate.directory(in: directory))
            }
            if session.container == nil, session.virtual == nil { session.phase = .stopped }
            if !Task.isCancelled {
                self.error = "The image could not be updated. Your current disk is unchanged.\n\(error.localizedDescription)"
                if wasRunning && !committed { await start(session) }
            }
        }
    }
}
