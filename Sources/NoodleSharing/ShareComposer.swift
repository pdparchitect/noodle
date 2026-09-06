import AppKit
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers

public enum ShareInput {
    case text(String)
    case file(URL)
    case provider(NSItemProvider)
}

@MainActor
public final class ShareComposerModel: ObservableObject {
    @Published public var destinations: [ShareDestination] = []
    @Published public var destinationID: UUID?
    @Published public var instruction = ""
    @Published public var text = ""
    @Published public var filenames: [String] = []
    @Published public var error: String?
    @Published public var isLoading = true
    @Published public var isSending = false
    public let inbox: SharedInbox
    private let requestID = UUID()
    private var loadTask: Task<Void, Never>?
    private var published = false

    public init(inbox: SharedInbox) { self.inbox = inbox }

    public func load(_ inputs: [ShareInput]) {
        loadTask = Task {
            do {
                destinations = try inbox.loadDestinations()
                destinationID = destinations.first?.id
                let draft = try inbox.draftDirectory(requestID)
                for input in inputs {
                    try Task.checkCancellation()
                    switch input {
                    case .text(let value): appendText(value)
                    case .file(let url):
                        let target = uniqueFile(in: draft, name: url.lastPathComponent)
                        try await Task.detached {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            try FileManager.default.copyItem(at: url, to: target)
                        }.value
                        filenames.append(target.lastPathComponent)
                    case .provider(let provider):
                        try await importProvider(provider, into: draft)
                    }
                }
            } catch is CancellationError {
                inbox.cancelDraft(requestID)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    public var canSend: Bool {
        !isLoading && !isSending && error == nil && destinationID != nil &&
            (!text.isEmpty || !filenames.isEmpty || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public func send() throws {
        guard canSend, let destinationID else { throw SharedInboxError.emptyContent }
        isSending = true
        do {
            let body = [instruction.trimmingCharacters(in: .whitespacesAndNewlines), text]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            try inbox.publish(SharedRequest(id: requestID, conversationID: destinationID, body: body, filenames: filenames))
            published = true
        } catch {
            isSending = false
            throw error
        }
    }

    public func cancel() {
        loadTask?.cancel()
        if !published { inbox.cancelDraft(requestID) }
    }

    private func appendText(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !text.components(separatedBy: "\n\n").contains(value) else { return }
        text = text.isEmpty ? value : text + "\n\n" + value
    }

    private func uniqueFile(in directory: URL, name: String) -> URL {
        let safeName = URL(fileURLWithPath: name.isEmpty ? "Attachment" : name).lastPathComponent
        let base = safeName == "request.json" ? "Shared request.json" : safeName
        var result = directory.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: result.path) {
            let url = URL(fileURLWithPath: base)
            result = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(suffix)")
            if !url.pathExtension.isEmpty { result.appendPathExtension(url.pathExtension) }
            suffix += 1
        }
        return result
    }

    private func importProvider(_ provider: NSItemProvider, into draft: URL) async throws {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await loadURL(provider)
            guard url.isFileURL else { throw SharedInboxError.invalidRequest }
            let target = uniqueFile(in: draft, name: provider.suggestedName ?? url.lastPathComponent)
            try await Task.detached {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: url, to: target)
            }.value
            filenames.append(target.lastPathComponent)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            // A shared web page stays a URL. Do not silently download it as an attachment.
            let url = try await loadURL(provider)
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw SharedInboxError.invalidRequest }
            appendText(url.absoluteString)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value: String = try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: NSString.self) { object, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let value = object as? String { continuation.resume(returning: value) }
                    else { continuation.resume(throwing: SharedInboxError.invalidRequest) }
                }
            }
            appendText(value)
        } else {
            guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { $0.conforms(to: .data) })
            else { throw SharedInboxError.invalidRequest }
            var name = provider.suggestedName ?? "Attachment"
            if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
            let target = uniqueFile(in: draft, name: name)
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw SharedInboxError.invalidRequest }
                        // The provider's temporary URL is valid only inside this callback.
                        try FileManager.default.copyItem(at: url, to: target)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            filenames.append(target.lastPathComponent)
        }
    }

    private func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = object as? URL { continuation.resume(returning: url) }
                else { continuation.resume(throwing: SharedInboxError.invalidRequest) }
            }
        }
    }
}

public struct ShareComposer: View {
    @ObservedObject private var model: ShareComposerModel
    private let send: () -> Void
    private let cancel: () -> Void

    public init(model: ShareComposerModel, send: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.model = model
        self.send = send
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "paperplane.fill").foregroundStyle(.tint)
                Text("Send to Agent").font(.headline)
                Spacer()
            }
            if model.destinations.isEmpty && !model.isLoading {
                Text("Open Noodle and create a bot or group, then share again.").foregroundStyle(.secondary)
            } else {
                Picker("Send to", selection: $model.destinationID) {
                    ForEach(model.destinations) { destination in
                        Label(destination.name, systemImage: destination.isGroup ? "person.3" : "person.crop.circle")
                            .tag(Optional(destination.id))
                    }
                }
            }
            if model.isLoading { ProgressView("Preparing shared items…").controlSize(.small) }
            if !model.text.isEmpty || !model.filenames.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.text.isEmpty { Text(model.text).font(.system(size: 12)).textSelection(.enabled) }
                        ForEach(model.filenames, id: \.self) { name in
                            Label(name, systemImage: "doc").lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("Add an instruction (optional)", text: $model.instruction, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(model.isSending ? "Sending…" : "Send", action: send)
                    .keyboardShortcut(.defaultAction).disabled(!model.canSend)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
