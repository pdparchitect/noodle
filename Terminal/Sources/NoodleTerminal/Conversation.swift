import Foundation
import HubLink
import SwiftTUI
import TerminalCore

/// One bot's or group's conversation: its messages, newest at the bottom, and the composer under them. Moving
/// through the messages chooses one for the palette to act on.
struct ConversationView: View {
    let row: TerminalHubs.Row
    let hubs: TerminalHubs
    let app: AppState
    let state: ConversationState
    var focus: FocusState<Focus?>.Binding
    /// Goes back to the list.
    let leave: @MainActor () -> Void
    /// A letter typed outside the message field starts a message with it.
    let typing: @MainActor @Sendable (KeyPress) -> KeyPressResult
    @State private var attachPath = ""
    @State private var attachProblem: String?

    /// How far Page Up and Page Down move.
    private static let page = 12

    private var chats: HubChats { row.chats }

    /// Up and Down go from message to message, the one chosen kept in view; past the newest, it follows new ones.
    private func choose(_ step: Int, in messages: [LinkMessage], _ proxy: ScrollViewProxy) -> KeyPressResult {
        guard !messages.isEmpty else { return .ignored }
        let index = state.message.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count
        let next = min(max(index + step, 0), messages.count - 1)
        state.message = messages[next].id
        state.followsNewest = step > 0 && next == messages.count - 1
        proxy.scrollTo(messages[next].id)
        return .handled
    }
    private var thread: HubThread { row.thread }

    var body: some View {
        let messages = chats.messages(of: thread)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                // Scrolled where it was left; a conversation not seen yet, or one following its newest, at the end.
                ScrollView(position: Binding(get: { state.offset }, set: { offset in
                    if offset.y < state.offset.y { state.followsNewest = false }
                    state.offset = offset
                })) {
                    VStack(alignment: .leading, spacing: 0) {
                        if chats.hasEarlier(thread) {
                            Text("Earlier messages: Load Earlier Messages in Control-K").foregroundStyle(.secondary).padding(.bottom, 1)
                        }
                        ForEach(messages) { message in
                            MessageView(message: message, author: chats.authorName(of: message, in: thread),
                                        delivery: chats.delivery(of: message), reason: chats.unsent[message.id] ?? nil, chats: chats,
                                        chosen: focus.wrappedValue == .messages && state.message == message.id)
                                .id(message.id)
                        }
                    }
                }
                .focused(focus, equals: .messages)
                .box(focused: focus.wrappedValue == .messages)
                .onKeyPress(.arrowUp) { _ in choose(-1, in: messages, proxy) }
                .onKeyPress(.arrowDown) { _ in choose(1, in: messages, proxy) }
                .onKeyPress(.pageUp) { _ in
                    state.followsNewest = false
                    proxy.scrollBy(y: -Self.page)
                    return .handled
                }
                .onKeyPress(.pageDown) { _ in
                    proxy.scrollBy(y: Self.page)
                    return .handled
                }
                .onKeyPress(.home) { _ in
                    state.followsNewest = false
                    return .ignored
                }
                .onKeyPress(.end) { _ in
                    state.followsNewest = true
                    return .ignored
                }
                .onKeyPress(.escape) { _ in
                    leave()
                    return .handled
                }
                .onKeyPress(.return) { _ in
                    focus.wrappedValue = .composer
                    return .handled
                }
                .onKeyPress(perform: typing)
                .onAppear {
                    if state.followsNewest { proxy.scrollTo(edge: .bottom) }
                }
                .onChange(of: messages.last?.id) { _, _ in
                    if state.followsNewest { proxy.scrollTo(edge: .bottom) }
                    chats.markRead(thread)
                }
            }
            Divider()
            composer
        }
        .onAppear { chats.markRead(thread) }
    }

    private var header: some View {
        HStack(spacing: 1) {
            Image(data: Pictures.png(for: thread, in: chats)).resizable().scaledToFit().frame(width: 4, height: 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 1) {
                    Text(thread.name).bold()
                    Spacer()
                    if !chats.isConnected { Text("offline").foregroundStyle(.red) }
                    SpaceMenu(hubs: hubs, title: chats.hubName)
                }
                if let line = headerLine {
                    Text(line).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal)
    }

    /// What holds the bot or what it is doing, or a group's bots.
    private var headerLine: String? {
        switch thread {
        case .bot(let bot):
            if let pause = bot.pause { return pause.shown() }
            let phase = bot.phase.map(Self.phaseName)
            return [bot.owner.map { "\($0)'s bot" }, phase, bot.status].compactMap { $0 }.joined(separator: " · ")
        case .group(let group):
            return chats.members(of: group).map(\.draft.name).joined(separator: ", ")
        }
    }

    static func phaseName(_ phase: LinkBotPhase) -> String {
        switch phase {
        case .offline: "Offline"
        case .starting: "Starting"
        case .ready: "Ready"
        case .working: "Working…"
        case .failed: "Needs a Kick"
        }
    }

    @ViewBuilder private var composer: some View {
        if let reason = chats.composerUnavailableReason(for: thread) {
            Text(reason).foregroundStyle(.secondary).padding(.horizontal)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.files, id: \.self) { file in
                    HStack(spacing: 1) {
                        Text("📎 \(file.lastPathComponent)")
                        Button("Remove") { state.files.removeAll { $0 == file } }
                    }
                }
                if state.attaching {
                    TextField("Path of a file on this Mac, then Return", text: $attachPath)
                        .focused(focus, equals: .composer)
                        .onSubmit { attach() }
                        .onKeyPress(.escape) { _ in
                            state.attaching = false
                            attachProblem = nil
                            focus.wrappedValue = nil
                            Task { focus.wrappedValue = .composer }
                            return .handled
                        }
                    if let attachProblem { Text(attachProblem).foregroundStyle(.red) }
                } else {
                    // No box: a line under the messages, its prompt lit while it has the keys.
                    HStack(spacing: 1) {
                        if focus.wrappedValue == .composer { Text("❯").bold().foregroundStyle(.tint) } else { Text("❯").foregroundStyle(.secondary) }
                    TextField(state.files.isEmpty ? "Message \(thread.name)" : "Add a message, or Return to send the files",
                              text: Binding(get: { state.draft }, set: { state.draft = $0 }))
                        .textFieldStyle(.plain)
                        .focused(focus, equals: .composer)
                        .onSubmit { send() }
                        .onKeyPress(.escape) { _ in
                            leave()
                            return .handled
                        }
                        // Up goes to the messages, the newest chosen, to act on one from the palette.
                        .onKeyPress(.arrowUp) { _ in
                            guard let last = chats.messages(of: thread).last else { return .ignored }
                            if state.message == nil { state.message = last.id }
                            focus.wrappedValue = .messages
                            return .handled
                        }
                    }
                    .padding(.vertical, 1)
                    // A click anywhere on the line gives it the keys; a plain field has no box to click.
                    .onTapGesture { focus.wrappedValue = .composer }
                }
            }
            .padding(.horizontal)
        }
    }

    /// Takes the file at the path typed, with `~` for the home folder, as a shell would.
    private func attach() {
        let typed = attachPath.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\ ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !typed.isEmpty else { return }
        let url = URL(fileURLWithPath: (typed as NSString).expandingTildeInPath)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
            attachProblem = "There is no file at \(url.path)."
            return
        }
        state.files.append(url)
        attachPath = ""
        attachProblem = nil
        state.attaching = false
        // The path field gives way to the message field; the keys go there once it is drawn.
        focus.wrappedValue = nil
        Task { focus.wrappedValue = .composer }
    }

    private func send() {
        let text = state.draft, files = state.files
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        state.draft = ""
        state.files = []
        state.followsNewest = true
        app.run { try await chats.send(text, files: files, to: thread) }
    }
}

/// A message as the terminal can show it: who wrote it and when, its words, its files by name with a picture of
/// those the Hub can preview, and its reactions.
struct MessageView: View {
    let message: LinkMessage
    let author: String
    let delivery: String?
    let reason: String?
    let chats: HubChats
    /// Outlined while chosen in the focused messages.
    var chosen = false
    /// How far a bubble stays from the other side, so the two sides read apart.
    private static let gap = 8

    private var mine: Bool { message.author == .you }

    /// As in a chat app: the bots' messages on the left, yours on the right in another colour.
    var body: some View {
        HStack(spacing: 0) {
            if mine { Spacer(minLength: Self.gap) }
            // Square: a terminal cannot round a corner, only leave its cell out.
            content
                .padding(.init(horizontal: 1, vertical: 1))
                .background {
                    if mine { Rectangle().fill(.selection) } else { Rectangle().fill(.fill) }
                }
                .overlay {
                    if chosen { Rectangle().strokeBorder(.tint, style: .heavy) }
                }
            if !mine { Spacer(minLength: Self.gap) }
        }
        .padding(.bottom, 1)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                Text(author).bold().foregroundStyle(message.author == .you ? .tint : .primary)
                Text(Self.time(message.createdAt)).foregroundStyle(.secondary)
                if let delivery {
                    if delivery == "Not delivered" { Text(delivery).foregroundStyle(.red) } else { Text(delivery).foregroundStyle(.secondary) }
                }
            }
            if !message.body.isEmpty { MarkdownText(message.body) }
            if let reason { Text(reason).foregroundStyle(.red) }
            ForEach(message.attachments) { attachment in
                if let url = attachment.url {
                    Text("🔗 " + (attachment.card?.title ?? url.absoluteString)).foregroundStyle(.secondary)
                } else {
                    Text("📎 \(attachment.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
                        .foregroundStyle(.secondary)
                    if attachment.pixelSize != nil || attachment.mediaType.hasPrefix("image/") {
                        AttachmentPicture(attachment: attachment, message: message, chats: chats)
                    }
                }
            }
            if !message.reactions.isEmpty {
                Text(message.reactions.map(\.emoji).joined(separator: " "))
            }
        }
    }

    /// The time alone today, with the day otherwise.
    static func time(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// A small picture of a file, asked of the Hub once and kept while the app runs.
struct AttachmentPicture: View {
    let attachment: LinkAttachment
    let message: LinkMessage
    let chats: HubChats
    @State private var picture: [UInt8]?

    @MainActor private static var kept: [UUID: [UInt8]] = [:]

    var body: some View {
        // Always something on screen, so the picture is asked for.
        VStack(alignment: .leading, spacing: 0) {
            if let picture, !picture.isEmpty {
                Image(data: picture).resizable().scaledToFit().frame(width: width, height: height, alignment: .leading)
            } else {
                Text(" ")
            }
        }
        .task(id: attachment.id) {
            if let kept = Self.kept[attachment.id] { return picture = kept }
            // A message still going up has no file on the Hub yet.
            guard chats.unsent[message.id] == nil,
                  let data = try? await chats.preview(of: attachment, in: message, pixels: 160) else { return }
            Self.kept[attachment.id] = [UInt8](data)
            picture = [UInt8](data)
        }
    }

    /// Cells are about twice as tall as wide, so a square picture takes twice as many columns as rows.
    private var height: Int { 10 }
    private var width: Int {
        guard let size = attachment.pixelSize else { return 20 }
        return max(4, min(48, Int((Double(size.width) / Double(size.height) * Double(height) * 2).rounded())))
    }
}
