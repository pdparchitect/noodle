import HubLink
import NoodleHubClient
import SwiftUI

/// A card in a Hub bot's conversation, opened live.
struct HubSurfaceTarget: Codable, Hashable {
    static let windowID = "hub-surface"
    let conversationID: UUID
    let attachmentID: UUID
    let title: String
}

/// Shows what a card points at on the Hub's Mac, and passes on what the person does. Closing
/// the window ends the stream.
struct HubSurfaceWindow: View {
    @Environment(NoodleStore.self) private var store
    let target: HubSurfaceTarget
    @State private var frame: SurfaceFrame?
    @State private var session: UUID?
    @State private var failure: String?

    var body: some View {
        ZStack {
            SurfaceView(frame: frame) { input in
                guard let session, let mirror = store.hubMirror(forConversation: target.conversationID) else { return }
                Task { try? await mirror.sendSurfaceInput(input, session: session) }
            }
            if frame == nil {
                if let failure { Text(failure).foregroundStyle(.secondary).padding() }
                else { ProgressView() }
            }
        }
        .navigationTitle(target.title)
        .frame(minWidth: 480, minHeight: 320)
        .task { await follow() }
    }

    private func follow() async {
        guard let mirror = store.hubMirror(forConversation: target.conversationID) else {
            failure = "Join that Noodle Hub again to open this."
            return
        }
        do {
            for try await event in try await mirror.openSurface(attachment: target.attachmentID, in: target.conversationID) {
                switch event {
                case .surfaceOpened(let id): session = id
                case .surfaceFrame(let id, let next) where id == session: frame = next
                default: break
                }
            }
            if frame == nil { failure = "The Hub could not show this." }
        } catch {
            failure = error.localizedDescription
        }
    }
}
