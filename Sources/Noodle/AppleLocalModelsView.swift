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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Local Models").font(.title2.bold())

                modelContent
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Button("Import Model…", action: importModel).disabled(checking || !supported || importing)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(importing)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(importing)
        .task {
            do {
                models = try storage.models()
                supported = try await AppleHostProbe().load().localModelsSupported == true
            } catch { self.error = error.localizedDescription }
            checking = false
        }
    }

    @ViewBuilder
    private var modelContent: some View {
        if checking || importing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(importing ? "Importing model files…" : "Checking local model support…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if models.isEmpty {
            Text(supported
                 ? "Import a downloaded MLX model folder."
                 : "Requires macOS 27 and a Noodle build with local model support.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            List(models) { model in
                let inUse = store.agents.contains { $0.harnessIdentifier == "apple" && $0.modelIdentifier == model.id }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.name).fontWeight(.medium).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Remove", role: .destructive) { remove(model) }
                        .disabled(inUse)
                        .help(inUse ? "Change bots using this model before removing it." : "Remove Noodle’s copy of this model.")
                }
                .padding(.vertical, 6)
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .frame(height: min(280, CGFloat(models.count) * 64 + 16))
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
