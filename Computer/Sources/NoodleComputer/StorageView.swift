// Adapted from ChatBotKit Studio's StorageView.
// Copyright 2026 CBK.AI LTD. Licensed under Apache-2.0.
import Combine
import ComputerEngine
import NoodleSettingsUI
import SwiftUI

struct StorageSettingsView: View {
    @State private var model: ComputerStore?
    @State private var error: String?

    var body: some View {
        Group {
            if let model { StorageView(model: model) }
            else {
                Form {
                    if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Refresh") { load() }
                }.formStyle(.grouped)
            }
        }
        .settingsContentSize(width: 580)
        .task { load() }
    }

    private func load() {
        do { model = try ComputerAppDelegate.loadLibrary(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct StorageView: View {
    @ObservedObject var model: ComputerStore
    @State private var confirming = false
    @State private var preview: StorageReport?
    @State private var running: [ComputerSession] = []
    @State private var busySessionIDs: Set<UUID> = []
    private var unavailable: Bool { model.storageBusy || model.storageOperationsBusy || !busySessionIDs.isEmpty }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private var confirmationTitle: String {
        running.isEmpty ? "Free up space?" : "Some computers are running"
    }

    private var confirmationMessage: String {
        let kept = "Your computers’ files are kept, but they can no longer go back to how they were before their last image upgrade. Removed downloads are fetched again when needed."
        guard !running.isEmpty else { return kept }
        let names = ListFormatter.localizedString(byJoining: running.map(\.computer.name))
        return "To free everything, \(names) must stop and restart, and unsaved work in them may be lost. Or free space from stopped computers only and leave running ones alone.\n\n" + kept
    }

    var body: some View {
        Form {
            if let report = model.storageReport {
                Section("Usage") {
                    LabeledContent("Free on this disk", value: size(report.freeBytes))
                    LabeledContent("Image and installer caches", value: size(report.cacheBytes))
                    LabeledContent("Runtime startup files", value: size(report.runtimeBytes))
                    LabeledContent("Computer disks and backups", value: size(report.computerBytes))
                    if report.sharedBytes > 0 {
                        LabeledContent("Shared between copies", value: size(report.sharedBytes))
                    }
                }
                Section {
                    LabeledContent("Can be freed", value: size(report.reclaimableBytes))
                    Text("Unused downloads, copies kept from before image upgrades, and space your computers no longer use inside their disks.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.storageCleaning, let progress = model.storageProgress {
                        ProgressView(value: progress.fraction) { Text(progress.label).font(.callout) }
                    }
                    HStack {
                        Button("Free Up Space") {
                            preview = report
                            running = model.storageRunningSessions
                            confirming = true
                        }
                            .disabled(unavailable || !report.canClean)
                        Spacer()
                        if model.storageBusy {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Inspecting \(ComputerAppIdentity.name) storage")
                        }
                        Button("Refresh") { model.inspectStorage() }
                            .disabled(unavailable)
                    }
                } header: { Text("Cleanup") }
            }
            if let error = model.storageError {
                Section { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if model.storageReport == nil {
                HStack {
                    Spacer()
                    if model.storageBusy {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Inspecting \(ComputerAppIdentity.name) storage")
                    }
                    Button("Refresh") { model.inspectStorage() }
                        .disabled(unavailable)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(Publishers.MergeMany(model.sessions.map { session in
            session.$phase.map { (session.id, $0.busy) }.eraseToAnyPublisher()
        })) { id, busy in
            if busy { busySessionIDs.insert(id) } else { busySessionIDs.remove(id) }
        }
        .task { model.inspectStorage() }
        .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
            if let preview {
                if running.isEmpty {
                    Button("Free Up \(size(preview.reclaimableBytes))") { model.cleanStorage(preview: preview) }
                } else {
                    Button("Stop Computers and Free \(size(preview.reclaimableBytes))", role: .destructive) {
                        model.cleanStorage(preview: preview, stopRunning: true)
                    }
                    let stoppedOnly = preview.reclaimableBytes(skipping: Set(running.map(\.computer.id)))
                    if stoppedOnly > 0 {
                        Button("Free \(size(stoppedOnly)) from Stopped Computers") {
                            model.cleanStorage(preview: preview, stopRunning: false)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }
}
