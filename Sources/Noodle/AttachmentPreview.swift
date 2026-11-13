import CryptoKit
import QuickLookThumbnailing
import AppletBridge
import ComputerBridge
import BrowserBridge
import ImageIO
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers

extension NoodleStore {
    func companions(in conversation: BotConversation) -> [ConversationAttachment] {
        ConversationAttachment.companions(newestFirst: messages(for: conversation).reversed().flatMap { attachments(for: $0) })
    }

    /// Whether `attachment` is a noodlet on a Noodle Hub, which can run on this Mac or there.
    func isHubNoodlet(_ attachment: ConversationAttachment) -> Bool {
        guard case .noodlet? = attachment.companion else { return false }
        return hubMirrors.contains { $0.owns(conversation: attachment.conversationID) }
    }

    /// Opens a link; a Hub's noodlet `at` the place the person asked for, if they did.
    func openCompanion(_ attachment: ConversationAttachment, at place: NoodletManifest.Placement? = nil) async throws {
        guard let link = attachment.companion, let url = attachment.url else { return }
        // On a Noodle Hub they run on the Hub's Mac, so their links open a live view instead.
        if hubMirrors.contains(where: { $0.owns(conversation: attachment.conversationID) }) {
            var target = HubSurfaceTarget(conversationID: attachment.conversationID, attachmentID: attachment.id,
                                          title: attachment.companionTitle)
            if case .noodlet = link { target.noodlet = true }
            if case .browser = link { target.browser = true }
            surfacePanels.open(target, store: self, at: place)
            return
        }
        switch link {
        case .browser: try await browsers.open(url)
        case .computer: try await computers.open(url)
        case .noodlet:
            try await noodletAnnotations.open(url, from: attachment.conversationID,
                                              region: KeyboardBindings.shared.binding(for: .annotateRegion),
                                              selection: KeyboardBindings.shared.binding(for: .annotateSelection))
        }
    }
}

/// Toolbar popover that reopens computers, browser pages and noodlets shared earlier in a conversation.
struct ConversationCompanionsMenu: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    @State private var isPresented = false

    var body: some View {
        let companions = store.companions(in: conversation)
        if !companions.isEmpty {
            Button { isPresented.toggle() } label: {
                Label("Shared", systemImage: "square.stack")
            }
            .help("Shared Computers, Browsers and Noodlets")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                CompanionList(companions: companions) { isPresented = false }
            }
        }
    }
}

struct CompanionList: View {
    @Environment(NoodleStore.self) private var store
    let companions: [ConversationAttachment]
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(companions) { attachment in
                    CompanionRow(attachment: attachment) {
                        dismiss()
                        Task { @MainActor in
                            do { try await store.openCompanion(attachment) }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            .padding(6)
        }
        // Keep the scrollbar clear of the popover's rounded corners.
        .contentMargins(.vertical, 16, for: .scrollIndicators)
        .frame(width: 340, height: min(CGFloat(companions.count) * CompanionRow.height + 12, 460))
    }
}

private struct CompanionRow: View {
    static let height: CGFloat = 70
    @Environment(NoodleStore.self) private var store
    let attachment: ConversationAttachment
    let open: () -> Void
    @State private var noodletPreview: NSImage?
    @State private var cardPicture: NSImage?
    @State private var noodletTitle: String?
    @State private var noodletUnavailable = false
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                preview
                    .frame(width: 84, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(noodletUnavailable ? "Noodlet unavailable" : attachment.companionKind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: Self.height - 2)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .task {
            // Noodlet previews live with the applet and are resolved on demand; other cards keep theirs on disk.
            if attachment.card != nil {
                let attachment = attachment, repository = store.repository
                cardPicture = await Task.detached(priority: .utility) {
                    repository.cardImage(of: attachment).flatMap(NSImage.init(data:))
                }.value
            }
            guard let url = attachment.url, NoodletLink.id(in: url) != nil else { return }
            if let shown = NoodletAttachmentCard.shown(url) {
                noodletTitle = shown.title
                noodletPreview = shown.image
                return
            }
            do {
                let preview = try await NoodletAttachmentCard.load(url, from: store.applets)
                noodletTitle = preview.title
                noodletPreview = preview.image
            } catch { noodletUnavailable = true }
        }
    }

    private var title: String { noodletTitle ?? attachment.companionTitle }

    @ViewBuilder private var preview: some View {
        if let image = cardPicture ?? noodletPreview {
            Image(nsImage: image).resizable().scaledToFill()
        } else if attachment.isComputerLink, let terminal = attachment.card?.detail {
            // A computer shared as its terminal shows its latest lines, as its card does.
            Text(terminal).font(.system(size: 4, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                .lineLimit(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(4)
                .background(.black)
        } else {
            Image(systemName: noodletUnavailable ? "questionmark.square.dashed" : attachment.companionSymbolName)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.5))
        }
    }
}
