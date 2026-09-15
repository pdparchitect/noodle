import AppKit
import NoodleCore
import SwiftUI

struct AppleLocalModelsView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var models: [AppleLocalModel] = []
    @State private var supported = false
    @State private var checking = true
    @State private var importing = false
    @State private var error: String?

    private var storage: AppleLocalModelStore { .init(repository: store.repository.rootURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local Models").font(.title2.bold())
            Text("Import an MLX Qwen2, Qwen3, or Llama chat model folder. Noodle keeps a private copy and loads it when a bot uses it.")
                .foregroundStyle(.secondary)
            Text("Local models currently support text and tools. For image attachments, choose Apple’s on-device model.")
                .font(.callout).foregroundStyle(.secondary)
            List(models) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).fontWeight(.medium)
                        Text(model.harnessModel.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { remove(model) }
                        .disabled(importing || store.agents.contains { $0.harnessIdentifier == "apple" && $0.modelIdentifier == model.id })
                        .help("Change any bots using this model before removing it.")
                }
            }
            .frame(minHeight: 160)
            if checking || importing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(importing ? "Importing model files…" : "Checking local model support…")
                }
            } else if !supported {
                Text("Local models require macOS 27 and a version of Noodle with local model support.")
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Import Model…", action: importModel).disabled(checking || !supported || importing)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(importing)
            }
        }
        .padding(24).frame(width: 580)
        .interactiveDismissDisabled(importing)
        .task {
            do {
                models = try storage.models()
                supported = try await AppleHostProbe().load().localModelsSupported == true
            } catch { self.error = error.localizedDescription }
            checking = false
        }
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.title = "Import MLX Model"
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let access = source.startAccessingSecurityScopedResource()
        let storage = storage
        importing = true
        error = nil
        Task {
            defer { if access { source.stopAccessingSecurityScopedResource() }; importing = false }
            do {
                _ = try await Task.detached { try storage.importModel(from: source) }.value
                models = try storage.models()
                await store.runtime.checkExternalInstallation(.apple)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove(_ model: AppleLocalModel) {
        do {
            try storage.remove(id: model.id)
            models = try storage.models()
            Task { await store.runtime.checkExternalInstallation(.apple) }
        } catch { self.error = error.localizedDescription }
    }
}
