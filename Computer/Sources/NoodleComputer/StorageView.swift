// Adapted from ChatBotKit Studio's StorageView.
// Copyright 2026 CBK.AI LTD. Licensed under Apache-2.0.
import Combine
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
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
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
    @State private var busySessionIDs: Set<UUID> = []
    private var unavailable: Bool { model.storageBusy || model.storageOperationsBusy || !busySessionIDs.isEmpty }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        Form {
            if let report = model.storageReport {
                Section("Usage") {
                    LabeledContent("Free on this disk", value: size(report.freeBytes))
                    LabeledContent("Image and installer caches", value: size(report.cacheBytes))
                    LabeledContent("Runtime startup files", value: size(report.runtimeBytes))
                    LabeledContent("Computer disks and backups", value: size(report.computerBytes))
                }
                Section {
                    Text("\(report.removableCount) cached items can be removed.")
                        .fixedSize(horizontal: false, vertical: true)
                    if report.orphanedBytes > 0 {
                        Text("\(size(Int64(report.orphanedBytes))) of unused image data can be removed.")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Clean Caches and Restart…") { preview = report; confirming = true }
                            .disabled(unavailable || !report.canClean)
                        Spacer()
                        if model.storageBusy {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Inspecting Noodle Computer storage")
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
                            .accessibilityLabel("Inspecting Noodle Computer storage")
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
        .confirmationDialog("Remove the previewed caches and restart running computers?", isPresented: $confirming) {
            Button("Clean Caches and Restart", role: .destructive) {
                if let preview { model.cleanStorage(preview: preview) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running computers will stop and restart. Unsaved work may be lost. Removed caches can be downloaded again. Computer disks and recovery copies will be preserved.")
        }
    }
}
