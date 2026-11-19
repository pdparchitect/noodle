import NoodleCore
import NoodleRuntime
import NoodleSettingsUI
import SwiftUI

/// What the Image Generation rows say about the models: the default, or what is missing.
public extension ImageGenerationController {
    var summary: String {
        if let downloadingID, models.isEmpty {
            return "Downloading \(ImageDownloadableModel.available.first { $0.id == downloadingID }?.name ?? "a model")…"
        }
        guard let model = currentModel else { return "No model downloaded yet" }
        return models.count == 1 ? model.name : "\(model.name) and \(models.count - 1) more"
    }
}

/// Noodle's own tools carry the same weight in a list as a connection's app icon.
public struct ImageGenerationIcon: View {
    let size: CGFloat
    public init(size: CGFloat) { self.size = size }
    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(.tint.opacity(0.18))
            .overlay {
                Image(systemName: "photo.badge.plus").font(.system(size: size * 0.62, weight: .medium)).foregroundStyle(.tint)
            }
            .frame(width: size, height: size)
    }
}

/// Image Generation in Settings > Tools: always there, never removed. Its models are managed
/// in the sheet behind Edit….
public struct ImageGenerationSettingsRow: View {
    let controller: ImageGenerationController
    @State private var editing = false
    public init(controller: ImageGenerationController) { self.controller = controller }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ImageGenerationIcon(size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Image Generation").font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    status
                }
                Text("Built in · Runs on this Mac").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(controller.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let failure = controller.failure {
                    Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Button("Edit…") { editing = true }
                    .buttonStyle(.accentLink)
                    .padding(.top, 3)
            }
        }
        .padding(14)
        .sheet(isPresented: $editing) { ImageModelsSheet(controller: controller).noodleSheetSizing() }
    }

    @ViewBuilder private var status: some View {
        if controller.downloadingID != nil && controller.models.isEmpty {
            SettingsStatusLabel(title: "Downloading", systemImage: "arrow.down.circle", color: .secondary)
        } else if controller.models.isEmpty {
            SettingsStatusLabel(title: "No model", systemImage: "arrow.down.circle", color: .orange)
        } else {
            SettingsStatusLabel(title: "Ready", systemImage: "checkmark.circle.fill", color: .green)
        }
    }
}

/// Downloads, the default and removal for every bot's image models.
public struct ImageModelsSheet: View {
    let controller: ImageGenerationController
    public init(controller: ImageGenerationController) { self.controller = controller }
    @Environment(\.dismiss) private var dismiss
    @State private var removing: ImageModel?
    @State private var listHeight: CGFloat = 0
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        formatter.zeroPadsFractionDigits = true
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Image Models").font(.title2.bold()).padding(.horizontal, 24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !controller.models.isEmpty { installed }
                        if !controller.available.isEmpty { available }
                    }
                    .padding(.horizontal, 24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Grows with the list up to a height that fits any screen, then scrolls.
                .frame(height: min(listHeight, 520))
                if let failure = controller.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 24)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .alert("Remove Model?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { model in
            Button("Remove", role: .destructive) { controller.remove(model) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { model in
            Text("Noodle’s copy of “\(model.name)” will be deleted. You can download it again later.")
        }
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installed").font(.headline)
            ForEach(controller.models) { model in
                let source = ImageDownloadableModel.available.first { $0.id == model.id }
                row(name: model.name, summary: model.summary, byteCount: model.byteCount, sourceURL: source?.sourceURL,
                    isDefault: model.id == controller.currentModel?.id) {
                    HStack(spacing: 12) {
                        if model.id != controller.currentModel?.id {
                            Button("Make Default") { controller.makeDefault(model) }.buttonStyle(.accentLink)
                        }
                        Button("Remove", role: .destructive) { removing = model }.buttonStyle(.accentLink)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var available: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available").font(.headline)
            ForEach(controller.available) { model in
                VStack(alignment: .leading, spacing: 8) {
                    row(name: model.name, summary: model.summary, byteCount: model.byteCount, sourceURL: model.sourceURL) {
                        if controller.downloadingID == model.id {
                            Button("Cancel") { controller.cancelDownload() }.disabled(controller.cancelling)
                        } else {
                            Button("Download") { controller.download(model) }.disabled(controller.downloadingID != nil)
                                .help(ProcessInfo.processInfo.physicalMemory < UInt64(ImageDownloadableModel.memory) << 30
                                      ? "Image models need about \(ImageDownloadableModel.memory) GB of memory; this Mac has less." : "")
                        }
                    }
                    if controller.downloadingID == model.id {
                        VStack(alignment: .leading, spacing: 5) {
                            ProgressView(value: controller.downloadProgress?.fraction ?? 0)
                            Text(downloadStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func row(name: String, summary: String, byteCount: Int64, sourceURL: URL?, isDefault: Bool = false,
                     @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.medium).lineLimit(2)
                    if isDefault {
                        Text("Default").font(.caption2).foregroundStyle(.tint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                            .help("Bots use this model unless they ask for another.")
                    }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)).foregroundStyle(.secondary)
                    if let sourceURL {
                        Link("Details", destination: sourceURL).help("Model details and licence on Hugging Face")
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 4)
            action()
        }
    }

    private var downloadStatus: String {
        if controller.cancelling { return "Cancelling…" }
        guard let progress = controller.downloadProgress else { return "Preparing download…" }
        switch progress.phase {
        case .downloading:
            return "Downloading \(Self.byteFormatter.string(fromByteCount: progress.completedBytes)) of \(Self.byteFormatter.string(fromByteCount: progress.totalBytes))…"
        case .verifying: return "Verifying model files…"
        case .importing: return "Importing model files…"
        }
    }
}
