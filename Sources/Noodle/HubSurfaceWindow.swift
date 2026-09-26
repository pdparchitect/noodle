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

/// Shows what a link points at on the Hub's Mac as live video, and passes on what the person
/// does over the same channel. Closing the window ends it, and the bot may go on.
struct HubSurfaceWindow: View {
    @Environment(NoodleStore.self) private var store
    let target: HubSurfaceTarget
    @State private var feed = SurfaceFeed()
    @State private var channel: LinkChannel?
    @State private var showing = false
    @State private var failure: String?

    var body: some View {
        ZStack {
            SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
            if !showing {
                if let failure { Text(failure).foregroundStyle(.secondary).padding() }
                else { ProgressView() }
            }
        }
        .navigationTitle(target.title)
        .frame(minWidth: 480, minHeight: 320)
        .task { await follow() }
        .onDisappear { channel?.cancel() }
    }

    private func follow() async {
        guard let mirror = store.hubMirror(forConversation: target.conversationID) else {
            failure = "Join that Noodle Hub again to open this."
            return
        }
        feed.onFirstPicture = { showing = true }
        do {
            let channel = try await mirror.openSurface(attachment: target.attachmentID, in: target.conversationID)
            self.channel = channel
            defer { channel.cancel() }
            for try await frame in channel.frames {
                if case .packets(let packets)? = LinkSurface.message(frame) { feed.receive(packets) }
            }
            if !showing { failure = "The Hub could not show this." }
        } catch {
            failure = error.localizedDescription
        }
    }
}
