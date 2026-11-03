import HubLink
import Intents
import SwiftUI
import UIKit

/// Noodle in the share sheet: what another app shared, sent to a bot or group of the Hubs this phone joined.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? []).flatMap { $0.attachments ?? [] }
        // A conversation iOS suggested, tapped at the top of the share sheet.
        let suggested = (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier.flatMap(ShareTarget.Key.init(identifier:))
        let composer = ShareComposer(providers: providers, suggested: suggested) { [weak self] sent in
            if sent {
                self?.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
        let host = UIHostingController(rootView: ShareView(composer: composer))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// What is being shared, and where it goes.
@MainActor @Observable final class ShareComposer {
    let targets: [ShareTarget]
    var chosen: ShareTarget?
    var text = ""
    private(set) var files: [OutgoingFile] = []
    private(set) var isLoading = true
    private(set) var isSending = false
    /// Files the Hub has so far.
    private(set) var sentFiles = 0
    private(set) var error: String?
    private let done: (Bool) -> Void

    init(providers: [NSItemProvider], suggested: ShareTarget.Key?, done: @escaping (Bool) -> Void) {
        var targets = AppGroup.hubs.map(ShareTargets.all(in:)) ?? []
        // The suggested conversation first, chosen.
        if let index = targets.firstIndex(where: { $0.key == suggested }) {
            let target = targets.remove(at: index)
            targets.insert(target, at: 0)
            chosen = target
        }
        self.targets = targets
        self.done = done
        Task {
            let shared = await SharedItems.load(providers)
            text = shared.text
            files = shared.files
            isLoading = false
        }
    }

    /// Several Hubs' bots may share a name, so each says its Hub.
    var showsHubs: Bool { Set(targets.map(\.key.hub)).count > 1 }

    var canSend: Bool {
        chosen != nil && !isLoading && !isSending
            && (!files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func remove(_ file: OutgoingFile) { files.removeAll { $0.id == file.id } }

    func send() {
        guard canSend, let chosen, let hubs = AppGroup.hubs else { return }
        isSending = true
        sentFiles = 0
        error = nil
        Task {
            do {
                try await SharedSend.send(text.trimmingCharacters(in: .whitespacesAndNewlines), files: files, to: chosen, hubs: hubs) {
                    sentFiles = $0
                }
                done(true)
            } catch {
                self.error = error.localizedDescription
                isSending = false
            }
        }
    }

    func cancel() { done(false) }
}

struct ShareView: View {
    @Bindable var composer: ShareComposer
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !composer.files.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(composer.files) { file in
                                    PendingFile(file: file) { composer.remove(file) }
                                }
                            }
                        }
                    }
                    TextField("Message", text: $composer.text, axis: .vertical)
                        .lineLimit(1...6)
                }
                if let error = composer.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    ForEach(shown) { target in
                        Button { composer.chosen = target } label: { row(target) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if composer.targets.isEmpty {
                    ContentUnavailableView("No Bots", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Join a Noodle Hub in Noodle first."))
                }
            }
            .searchField(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .disabled(composer.isSending)
            .safeAreaInset(edge: .bottom) {
                if composer.isSending {
                    ProgressView(value: Double(composer.sentFiles), total: Double(composer.files.count + 1))
                        .padding()
                        .background(.bar)
                }
            }
            .navigationTitle(composer.chosen?.name ?? "Noodle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { composer.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { composer.send() }.disabled(!composer.canSend)
                }
            }
        }
    }

    private var shown: [ShareTarget] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? composer.targets : composer.targets.filter { $0.name.localizedStandardContains(term) }
    }

    private func row(_ target: ShareTarget) -> some View {
        HStack(spacing: 12) {
            ConversationAvatar(target: target, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).lineLimit(1)
                if composer.showsHubs {
                    Text(target.hubName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if composer.chosen?.key == target.key {
                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A shared file, with a button to leave it out.
private struct PendingFile: View {
    let file: OutgoingFile
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if file.mediaType.hasPrefix("image/"), let image = DecodedImages.downsampled(file.url, to: 192) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
                        Text(file.filename).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .padding(6)
                }
            }
            .frame(width: 72, height: 72)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(3)
            .accessibilityLabel("Remove \(file.filename)")
        }
        .padding(.vertical, 4)
    }
}
