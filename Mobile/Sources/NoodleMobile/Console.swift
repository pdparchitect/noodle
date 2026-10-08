import GameController
import HubLink
import NoodleBrand
import NoodletRuntime
import SwiftUI

/// A noodlet in the console's library: its newest share in any of the person's conversations.
struct ConsoleTitle: Identifiable {
    let hub: HubChats
    let thread: HubThread
    let attachment: LinkAttachment
    let sharedAt: Date
    let isGame: Bool

    var id: UUID { attachment.id }

    /// The noodlet itself, whichever conversation shared it.
    @MainActor var key: String? { Console.noodlet(of: attachment).map { "\(hub.pairing.directory.path):\($0)" } }
}

/// A noodlet's share, kept once the console found it earlier in a conversation than this phone keeps.
struct ConsoleShare: Codable {
    var attachment: LinkAttachment
    var sharedAt: Date
}

/// What the console found in each of a Hub's conversations before the messages this phone keeps,
/// so a long history is looked through once.
struct ConsoleHistory: Codable {
    struct Scanned: Codable {
        /// Where the part looked through starts; nothing before it is left once it reaches 0.
        var from: Int
        var shares: [ConsoleShare]
    }

    var conversations: [UUID: Scanned] = [:]

    @MainActor static func url(for hub: HubChats) -> URL { hub.pairing.directory.appendingPathComponent("console.json") }
}

struct ConsoleShelf: Identifiable {
    enum Kind { case games, noodlets }

    let kind: Kind
    let titles: [ConsoleTitle]

    var id: Kind { kind }

    var name: String {
        switch kind {
        case .games: "Games"
        case .noodlets: "Noodlets"
        }
    }
}

/// The card chosen on the console's shelves.
struct ConsoleSelection: Equatable {
    var shelf = 0
    var item = 0

    /// `counts` holds how many cards each shelf has, none empty.
    func moved(_ input: HardwareGamepad.MenuInput, counts: [Int]) -> Self {
        var next = clamped(counts)
        guard !counts.isEmpty else { return next }
        switch input {
        case .left: next.item = max(next.item - 1, 0)
        case .right: next.item = min(next.item + 1, counts[next.shelf] - 1)
        case .up where next.shelf > 0:
            next.shelf -= 1
            next.item = min(next.item, counts[next.shelf] - 1)
        case .down where next.shelf < counts.count - 1:
            next.shelf += 1
            next.item = min(next.item, counts[next.shelf] - 1)
        default: break
        }
        return next
    }

    /// The same card, or the nearest one left after the shelves changed.
    func clamped(_ counts: [Int]) -> Self {
        guard !counts.isEmpty else { return Self() }
        let shelf = min(shelf, counts.count - 1)
        return Self(shelf: shelf, item: min(item, max(counts[shelf] - 1, 0)))
    }
}

/// The phone's own controller while the console shows on a TV: a d-pad to move and a button to play.
enum ConsolePad {
    static let gamepad = Gamepad(pads: [Gamepad.Pad(left: "left", right: "right", up: "up", down: "down")],
                                 buttons: [Gamepad.Button(key: "enter", label: "A")])

    static func input(for change: GamepadKeyChange) -> HardwareGamepad.MenuInput? {
        guard change.pressed else { return nil }
        switch change.key {
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        case "enter": return .choose
        default: return nil
        }
    }
}

/// The phone as a games console: every noodlet the person's bots shared on their Hubs, games first,
/// played on the phone or, with a TV connected, on the TV with the phone as the controller.
@MainActor @Observable final class Console {
    private(set) var hubs: [HubChats] = []
    var selection = ConsoleSelection()
    /// The noodlet playing, in place of the shelves.
    private(set) var playing: ConsoleTitle?
    /// Whether the start-up has finished and the shelves show.
    var booted = false
    private(set) var isScanning = false
    /// Cards with their pictures and names, as fetched.
    private var cards: [UUID: LinkAttachment] = [:]
    private var histories: [URL: ConsoleHistory] = [:]
    /// Whether each noodlet is a game, read from its files once per visit to the shelves.
    @ObservationIgnored private var games: [String: Bool] = [:]
    /// A controller in hand steers the shelves.
    @ObservationIgnored let hardware = HardwareGamepad()

    func show(_ hubs: [HubChats]) {
        self.hubs = hubs
        for hub in hubs where histories[ConsoleHistory.url(for: hub)] == nil {
            let url = ConsoleHistory.url(for: hub)
            histories[url] = (try? JSONDecoder().decode(ConsoleHistory.self, from: Data(contentsOf: url))) ?? ConsoleHistory()
        }
    }

    var shelves: [ConsoleShelf] { Self.shelves(Self.titles(shares)) }

    var titles: [ConsoleTitle] { shelves.flatMap(\.titles) }

    var selected: ConsoleTitle? {
        let shelves = shelves
        let at = selection.clamped(shelves.map(\.titles.count))
        return shelves.indices.contains(at.shelf) ? shelves[at.shelf].titles[at.item] : nil
    }

    /// Every share of a noodlet in the conversations listed, from the history looked through and the messages this phone keeps.
    private var shares: [ConsoleTitle] {
        hubs.flatMap { hub in
            let history = histories[ConsoleHistory.url(for: hub)]
            return hub.listedThreads.flatMap { thread in
                ((history?.conversations[thread.conversationID]?.shares ?? []) + Self.shares(in: hub.messages(of: thread))).map {
                    ConsoleTitle(hub: hub, thread: thread, attachment: $0.attachment, sharedAt: $0.sharedAt,
                                 isGame: isGame($0.attachment, in: hub))
                }
            }
        }
    }

    static func shares(in messages: [LinkMessage]) -> [ConsoleShare] {
        messages.flatMap { message -> [ConsoleShare] in
            guard case .bot = message.author else { return [] }
            return message.attachments.filter { $0.liveKind == .noodlet }.map { ConsoleShare(attachment: $0, sharedAt: message.createdAt) }
        }
    }

    /// One title per noodlet, by its newest share, newest first.
    static func titles(_ shares: [ConsoleTitle]) -> [ConsoleTitle] {
        var seen = Set<String>()
        return shares.sorted { $0.sharedAt > $1.sharedAt }.filter { $0.key.map { seen.insert($0).inserted } ?? false }
    }

    static func shelves(_ titles: [ConsoleTitle]) -> [ConsoleShelf] {
        [ConsoleShelf(kind: .games, titles: titles.filter(\.isGame)), ConsoleShelf(kind: .noodlets, titles: titles.filter { !$0.isGame })]
            .filter { !$0.titles.isEmpty }
    }

    /// The noodlet a link points at, by the ID its files are kept under.
    nonisolated static func noodlet(of attachment: LinkAttachment) -> String? { attachment.url.flatMap { $0.host?.lowercased() } }

    /// Whether a noodlet is a game, which only its files say: known once it has been opened on this phone.
    static func isGame(_ attachment: LinkAttachment, cache: URL) -> Bool {
        guard let id = noodlet(of: attachment) else { return false }
        let folder = cache.appendingPathComponent(id)
        for revision in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !revision.hasPrefix(".") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(revision).appendingPathComponent("noodlet.json")),
                  let manifest = try? JSONDecoder().decode(NoodletManifest.self, from: data) else { continue }
            return manifest.controls != nil || manifest.category == "games"
        }
        return false
    }

    private func isGame(_ attachment: LinkAttachment, in hub: HubChats) -> Bool {
        let key = "\(hub.pairing.directory.path):\(Self.noodlet(of: attachment) ?? "")"
        if let known = games[key] { return known }
        let known = Self.isGame(attachment, cache: hub.noodletCache)
        games[key] = known
        return known
    }

    /// The card a title shows: with its picture and name once fetched.
    func shown(_ title: ConsoleTitle) -> LinkAttachment { cards[title.id] ?? title.attachment }

    func fetchCard(_ title: ConsoleTitle) async {
        guard cards[title.id] == nil else { return }
        cards[title.id] = await title.hub.sharedAttachment(title.attachment, in: title.thread)
    }

    /// Looks through each conversation's messages before those this phone keeps, newest first, once.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        for hub in hubs {
            let url = ConsoleHistory.url(for: hub)
            for thread in hub.listedThreads {
                var scanned = histories[url]?.conversations[thread.conversationID]
                guard var from = scanned?.from ?? hub.loadedStart(of: thread), scanned == nil || from > 0 else { continue }
                var shares = scanned?.shares ?? []
                do {
                    repeat {
                        if from > 0 {
                            let page = try await hub.messages(of: thread, before: from)
                            shares = Self.shares(in: page.messages) + shares
                            from = page.messages.isEmpty ? 0 : page.start ?? 0
                        }
                        scanned = ConsoleHistory.Scanned(from: from, shares: shares)
                        histories[url, default: ConsoleHistory()].conversations[thread.conversationID] = scanned
                        try? JSONEncoder().encode(histories[url]).write(to: url, options: .atomic)
                    } while from > 0
                } catch {
                    // The Hub is out of reach: the rest waits for the next visit.
                    break
                }
            }
        }
    }

    func move(_ input: HardwareGamepad.MenuInput) {
        selection = selection.moved(input, counts: shelves.map(\.titles.count))
    }

    func select(_ title: ConsoleTitle) {
        for (shelf, row) in shelves.enumerated() {
            if let item = row.titles.firstIndex(where: { $0.id == title.id }) { selection = ConsoleSelection(shelf: shelf, item: item) }
        }
    }

    /// A controller's press on the shelves.
    func respond(_ input: HardwareGamepad.MenuInput) {
        guard booted, playing == nil else { return }
        switch input {
        case .choose: if let selected { play(selected) }
        case .back: break
        default: move(input)
        }
    }

    /// The noodlet takes the controller in hand while it plays.
    func play(_ title: ConsoleTitle) {
        select(title)
        releaseController()
        playing = title
    }

    /// Back to the shelves, where a noodlet just opened may now be known as a game.
    func leave() {
        playing = nil
        games = [:]
    }

    /// Switches to another noodlet from the menu over the one playing.
    func open(_ attachment: LinkAttachment) {
        if let title = titles.first(where: { $0.id == attachment.id }) { play(title) }
    }

    /// The controller in hand steers the shelves, taking it back from a noodlet that has closed.
    func takeController() {
        hardware.attach(Gamepad()) { _ in }
        hardware.menu = { [weak self] in self?.respond($0) }
    }

    func releaseController() {
        hardware.menu = nil
        hardware.detach()
    }
}

/// The console, over the whole screen: its start-up, then the shelves, and the noodlet chosen.
struct ConsoleView: View {
    let hubs: [HubChats]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ScreenControlHaptics.key) private var haptics = false
    @State private var console = Console()
    @State private var tvAvailable = false

    var body: some View {
        Group {
            if let playing = console.playing {
                NoodletScreen(chats: playing.hub, thread: playing.thread, attachment: console.shown(playing))
                    .id(playing.id)
                    .environment(\.noodletMenu, NoodletMenu(choices: console.titles.map(console.shown), current: playing.id, fromPlay: true) { next in
                        console.open(next)
                    })
                    .environment(\.closeNoodlet) { console.leave() }
            } else {
                shelves
            }
        }
        .onAppear {
            ScreenOrientation.resting = .landscape
            ScreenOrientation.hold(nil)
            KeepAwake.resting = true
            KeepAwake.set(false)
        }
        .onDisappear {
            console.releaseController()
            ScreenOrientation.resting = nil
            ScreenOrientation.hold(nil)
            KeepAwake.resting = false
            KeepAwake.set(false)
        }
        .task {
            console.show(hubs)
            await console.scan()
        }
    }

    /// On the phone, or on the TV while the phone becomes its controller.
    private var shelves: some View {
        ZStack {
            if !console.booted {
                ConsoleStart(console: console)
            } else if tvAvailable {
                ConsoleController(console: console, haptics: haptics) { dismiss() }
            } else {
                ConsoleHome(console: console, onTV: false) { dismiss() }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { console.takeController() }
        .externalScreen(enabled: .constant(true), available: $tvAvailable) {
            ConsoleScreen(console: console)
        }
    }
}

/// What the TV shows: the same start-up and shelves, larger.
private struct ConsoleScreen: View {
    let console: Console

    var body: some View {
        if console.booted { ConsoleHome(console: console, onTV: true) } else { ConsoleStart(console: console, onTV: true) }
    }
}

/// The wordmark written on as the console starts, as a console shows its maker's mark.
private struct ConsoleStart: View {
    let console: Console
    var onTV = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var written = false

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.4, 420)
            Wordmark(progress: written ? 1 : 0, wordWidth: width)
                .stroke(.white, style: StrokeStyle(lineWidth: Wordmark.lineWidth(forWordWidth: width), lineCap: .round, lineJoin: .round))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .ignoresSafeArea()
        .accessibilityLabel("Noodle")
        .task {
            withAnimation(.easeInOut(duration: 1.4)) { written = true }
            // The phone's start-up leads; the TV's only draws along.
            guard !onTV else { return }
            if reduceMotion { return console.booted = true }
            try? await Task.sleep(for: .seconds(1.9))
            withAnimation(.easeOut(duration: 0.35)) { console.booted = true }
        }
    }
}

/// One shelf of cards at a time, stacked with the chosen one in front, named large under them over
/// its own picture; the shelves are tabs along the top.
private struct ConsoleHome: View {
    let console: Console
    let onTV: Bool
    var exit: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = ConsoleStack.cardWidth(in: proxy.size, onTV: onTV)
            let shelves = console.shelves
            let at = console.selection.clamped(shelves.map(\.titles.count))
            ZStack(alignment: .top) {
                ConsoleBackdrop(image: console.selected.flatMap { console.shown($0).card?.image })
                VStack(spacing: 0) {
                    ConsoleTopBar(onTV: onTV, shelves: shelves.map(\.name), shelf: at.shelf, exit: exit)
                    Spacer(minLength: 0)
                    if shelves.indices.contains(at.shelf) {
                        let titles = shelves[at.shelf].titles
                        ConsoleCarousel(count: titles.count, selected: at.item, cardWidth: cardWidth, interactive: !onTV) { item, chosen in
                            ConsoleCard(attachment: console.shown(titles[item]), isGame: titles[item].isGame, chosen: chosen, width: cardWidth)
                                .task { await console.fetchCard(titles[item]) }
                        } select: { item in
                            console.select(titles[item])
                        } activate: { item in
                            console.play(titles[item])
                        }
                        .id(shelves[at.shelf].id)
                        .transition(.opacity)
                    }
                    if let selected = console.selected {
                        ConsoleCaption(title: console.shown(selected).liveTitle, detail: subtitle(selected), cardWidth: cardWidth, onTV: onTV)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, onTV ? 48 : 12)
                .padding(.bottom, onTV ? 48 : 12)
                .animation(.easeOut(duration: 0.25), value: at.shelf)
                if shelves.isEmpty {
                    Group {
                        if console.isScanning || console.hubs.contains(where: { !$0.isLoaded }) {
                            ProgressView().tint(.white)
                        } else {
                            ContentUnavailableView("No Noodlets", systemImage: "gamecontroller")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // The backdrop's picture fills the screen without making it any larger.
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .foregroundStyle(.white)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(edges: onTV ? .all : [])
    }

    private func subtitle(_ title: ConsoleTitle) -> String {
        console.hubs.count > 1 ? "\(title.thread.name) · \(title.hub.pairing.hubName)" : title.thread.name
    }
}

/// The chosen card's name, and what it belongs to, under the stack.
private struct ConsoleCaption: View {
    let title: String
    let detail: String?
    let cardWidth: CGFloat
    let onTV: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: cardWidth * 0.085, weight: .bold, design: .rounded)).lineLimit(1)
            if let detail { Text(detail).font(onTV ? .title3 : .subheadline).foregroundStyle(.white.opacity(0.7)) }
        }
        .padding(.top, cardWidth * 0.1)
        .padding(.horizontal, 24)
        .id(title)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: title)
    }
}

/// How Play stacks its cards.
enum ConsoleStack {
    /// The front card's width: as large as the screen allows with room for the stack around it.
    static func cardWidth(in size: CGSize, onTV: Bool) -> CGFloat {
        min(size.width * (onTV ? 0.36 : 0.42), size.height * (onTV ? 0.42 : 0.5) * 16 / 9)
    }

    /// Where a card sits, `offset` cards from the front: sideways, smaller, turned and further back.
    static func placement(offset: CGFloat, cardWidth: CGFloat) -> (x: CGFloat, scale: CGFloat, angle: Double, opacity: Double) {
        let distance = abs(offset), side: CGFloat = offset < 0 ? -1 : 1
        let x = side * (min(distance, 1) * cardWidth * 0.62 + max(distance - 1, 0) * cardWidth * 0.24)
        let scale = 1 - min(distance, 3) * 0.12
        let angle = -Double(max(min(offset, 1), -1)) * 42
        let opacity = Double(max(0, 1 - max(distance - 2.5, 0)))
        return (x, scale, angle, opacity)
    }
}

/// Cards stacked in depth: the chosen one in front, the others turned away and shrinking to each
/// side. A swipe moves along them, a tap brings one to the front and a tap on the front one plays it.
struct ConsoleCarousel<Card: View>: View {
    let count: Int
    let selected: Int
    let cardWidth: CGFloat
    /// Whether touches steer it; on the TV only a controller does.
    var interactive = true
    @ViewBuilder let card: (_ index: Int, _ chosen: Bool) -> Card
    var select: (Int) -> Void = { _ in }
    var activate: (Int) -> Void = { _ in }
    /// How far a finger has dragged the stack, in cards, until it lets go.
    @State private var dragged: CGFloat = 0

    var body: some View {
        let position = CGFloat(selected) - dragged
        let last = max(0, min(count - 1, Int(position.rounded(.up)) + 4))
        let shown = Array(min(max(0, Int(position.rounded(.down)) - 4), last)...last)
        ZStack {
            ForEach(count == 0 ? [] : shown, id: \.self) { index in
                let offset = CGFloat(index) - position
                let place = ConsoleStack.placement(offset: offset, cardWidth: cardWidth)
                card(index, index == selected && dragged == 0)
                    .rotation3DEffect(.degrees(place.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .scaleEffect(place.scale)
                    .offset(x: place.x)
                    .opacity(place.opacity)
                    .brightness(-min(abs(offset), 2) * 0.12)
                    .zIndex(-Double(abs(offset)))
                    .onTapGesture {
                        guard interactive else { return }
                        if index == selected { activate(index) } else { withAnimation(.spring(duration: 0.35, bounce: 0.2)) { select(index) } }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { activate(index) }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardWidth * 9 / 16 * 1.12)
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.35, bounce: 0.2), value: selected)
        .gesture(DragGesture(minimumDistance: 10).onChanged { drag in
            guard interactive else { return }
            dragged = drag.translation.width / (cardWidth * 0.5)
        }.onEnded { drag in
            guard interactive else { return }
            let target = (CGFloat(selected) - drag.predictedEndTranslation.width / (cardWidth * 0.5)).rounded()
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                dragged = 0
                select(Int(max(0, min(CGFloat(count - 1), target))))
            }
        })
    }
}

/// The menu the controller's View button opens over a noodlet started from Play: the same stack of
/// cards, ending with the way back to Play's home.
struct ConsoleMenuView: View {
    let menu: NoodletMenu
    let selected: Int

    var body: some View {
        GeometryReader { proxy in
            let onTV = proxy.size.width > 1200
            let cardWidth = ConsoleStack.cardWidth(in: proxy.size, onTV: onTV)
            let items = menu.items
            ZStack {
                Color.black.opacity(0.8)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ConsoleCarousel(count: items.count, selected: selected, cardWidth: cardWidth, interactive: false) { index, chosen in
                        switch items[index] {
                        case .noodlet(let attachment):
                            ConsoleCard(attachment: attachment, isGame: false, chosen: chosen, width: cardWidth)
                        case .closeGame:
                            ConsoleSymbolCard(symbol: "house.fill", chosen: chosen, width: cardWidth)
                        }
                    }
                    if items.indices.contains(selected) {
                        ConsoleCaption(title: title(items[selected]), detail: nil, cardWidth: cardWidth, onTV: onTV)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func title(_ item: NoodletMenu.Item) -> String {
        switch item {
        case .noodlet(let attachment): attachment.liveTitle
        case .closeGame: "Home"
        }
    }
}

/// The chosen card's picture, blurred and dimmed behind everything.
private struct ConsoleBackdrop: View {
    let image: Data?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.07, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
            if let image, let picture = UIImage(data: image) {
                Color.clear.overlay { Image(uiImage: picture).resizable().scaledToFill() }
                    .blur(radius: 40).opacity(0.45)
                    .transition(.opacity)
                    .id(image.hashValue)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.4), value: image?.hashValue)
    }
}

private struct ConsoleCard: View {
    let attachment: LinkAttachment
    let isGame: Bool
    let chosen: Bool
    let width: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.07, style: .continuous)
        ZStack {
            shape.fill(Color(white: 0.16))
            if let data = attachment.card?.image, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: isGame ? "gamecontroller.fill" : attachment.liveSymbol).font(.system(size: width * 0.16))
                    Text(attachment.liveTitle).font(.system(size: width * 0.07, weight: .semibold)).lineLimit(1).padding(.horizontal, 8)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white, lineWidth: chosen ? max(width * 0.012, 3) : 0))
        .shadow(color: .white.opacity(chosen ? 0.35 : 0), radius: width * 0.08)
        .animation(.easeOut(duration: 0.2), value: chosen)
        .accessibilityElement()
        .accessibilityLabel(attachment.liveTitle)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A card holding only a symbol, such as the way back to Play's home.
private struct ConsoleSymbolCard: View {
    let symbol: String
    let chosen: Bool
    let width: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.07, style: .continuous)
        shape.fill(Color(white: 0.18))
            .overlay(Image(systemName: symbol).font(.system(size: width * 0.16)).foregroundStyle(.white.opacity(0.85)))
            .frame(width: width, height: width * 9 / 16)
            .overlay(shape.strokeBorder(.white, lineWidth: chosen ? max(width * 0.012, 3) : 0))
            .shadow(color: .white.opacity(chosen ? 0.35 : 0), radius: width * 0.08)
    }
}

/// The shelves as tabs, the time and the controllers connected, as a console shows them, and the way out on the phone.
private struct ConsoleTopBar: View {
    let onTV: Bool
    let shelves: [String]
    let shelf: Int
    var exit: (() -> Void)?
    /// Bumped as controllers come and go.
    @State private var changes = 0

    var body: some View {
        HStack(spacing: onTV ? 28 : 18) {
            if let exit {
                Button("Done", action: exit).buttonStyle(.glass)
            }
            ForEach(Array(shelves.enumerated()), id: \.offset) { index, name in
                Text(name)
                    .font(onTV ? .title2.weight(.bold) : .headline)
                    .foregroundStyle(.white.opacity(index == shelf ? 1 : 0.45))
            }
            Spacer()
            let _ = changes
            ForEach(ConnectedController.list(GCController.controllers())) { controller in
                Image(systemName: controller.symbol)
            }
            TimelineView(.everyMinute) { context in
                Text(context.date, style: .time).monospacedDigit()
            }
        }
        .font(onTV ? .title3.weight(.medium) : .subheadline.weight(.medium))
        .padding(.horizontal, onTV ? 120 : 16)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in changes += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in changes += 1 }
    }
}

/// The phone while the console shows on the TV: a controller, or the controllers in hand once one is used.
private struct ConsoleController: View {
    let console: Console
    let haptics: Bool
    let exit: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "tv").font(.system(size: 34))
                if let selected = console.selected {
                    Text(console.shown(selected).liveTitle).font(.title3.weight(.semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.bottom, 120)
            if console.hardware.controller == nil {
                GamepadOverlay(gamepad: ConsolePad.gamepad, haptics: haptics) { change in
                    if let input = ConsolePad.input(for: change) { console.respond(input) }
                }
            } else {
                ConnectedControllersView().padding(.top, 120)
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Done", action: exit).buttonStyle(.glass).padding(.horizontal, 12)
        }
    }
}
