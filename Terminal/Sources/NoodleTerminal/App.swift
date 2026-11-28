import Foundation
import HubLink
import Observation
import TerminalCore
import TerminalScreen
#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct NoodleTerminalApp {
    static let usage = """
        OVERVIEW: Chat with the bots and groups on your Noodle Hub.

        USAGE: noodle

        OPTIONS:
          -h, --help              Show help information.

        Type / in the app to see what it can do.

        """

    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains(where: { $0 == "-h" || $0 == "--help" }) {
            print(usage, terminator: "")
            return
        }
        if let unknown = arguments.first {
            FileHandle.standardError.write(Data("Error: Unknown option '\(unknown)'\nUsage: noodle\n  See 'noodle --help' for more information.\n".utf8))
            exit(64)
        }
        guard Console.isTerminal else {
            FileHandle.standardError.write(Data("noodle needs a terminal to run in.\n".utf8))
            exit(1)
        }
        await App().run()
    }
}

/// A list under the message field to choose from: bots and groups, commands, the choices of a form, or a question.
struct Picker {
    struct Item: Equatable {
        var id: String
        var label: String
        var detail = ""
        /// Marked with a check, as what is chosen now.
        var current = false
    }

    enum Result {
        case chose(Item)
        /// What is checked when a list of several choices is confirmed.
        case confirmed(Set<String>)
        case cancelled
    }

    /// What the list holds, in the message field's hint: "Type to narrow bots and groups".
    var title: String
    /// What Return does, in the hint.
    var verb = "opens"
    /// Words above the list, wrapped to fit, such as what a question means.
    var message: [String] = []
    /// Read on every frame, so the list keeps up with the Hub.
    var items: @MainActor () -> [Item]
    var filterable = true
    /// Set for a list where several can be chosen: Space checks and unchecks, Return confirms.
    var checked: Set<String>?
    /// Keys that choose an item at once, such as y and n for a question.
    var shortcuts: [String: String] = [:]
    var query = ""
    var selection = 0
    var finish: @MainActor (Result) -> Void = { _ in }

    @MainActor func shown() -> [Item] {
        filterable ? narrowed(items(), by: query, name: { $0.label }, detail: { $0.detail }) : items()
    }
}

/// A question answered in the message field, one field of a form at a time.
struct Prompt {
    /// The form, such as "New bot".
    var title: String
    /// The field, such as "Name".
    var label: String
    var placeholder: String
    var finish: @MainActor (String?) -> Void
}

/// A slash command, with what it does given the rest of the line.
struct Command {
    var name: String
    /// What it takes after its name, as the list shows it: "/file path".
    var argument: String?
    var summary: String
    /// Whether choosing it puts it in the field to be finished, rather than running it.
    var fills = false
    var isAvailable: @MainActor () -> Bool = { true }
    /// What may follow its name, offered as it is typed.
    var options: (@MainActor () -> [Picker.Item])?
    var run: @MainActor (String) -> Void
}

/// One conversation full screen, the message field pinned at the bottom, and slash commands for the rest. Only
/// the lines that change are drawn again.
@MainActor final class App {
    let console = Console()
    let hubs = TerminalHubs(directory: App.directory, deviceName: TerminalHubs.standardDeviceName)
    var current: TerminalHubs.Row.Key?
    var input: [Character] = []
    var cursor = 0
    /// How many lines the transcript is scrolled up from its end.
    var scroll = 0
    var suggestion = 0
    var picker: Picker? { didSet { scheduleRedraw() } }
    var prompt: Prompt? { didSet { scheduleRedraw() } }
    var notice: String? { didSet { scheduleRedraw() } }
    /// The message chosen with Up and Down, which message commands act on.
    var selected: UUID? {
        didSet {
            reveal = selected != nil
            scheduleRedraw()
        }
    }
    /// The messages the last search found, once the Hubs answer.
    var found: [TerminalHubs.MessageMatch]?
    /// Each Hub's users, kept while the app runs so a user's choices and the list agree.
    var users: [ObjectIdentifier: HubUsers] = [:]
    lazy var commands: [Command] = makeCommands()

    private var reveal = false
    private var decoder = KeyDecoder()
    private var onScreen: [String] = []
    private var cursorAt = (row: 1, column: 1)
    private var redrawScheduled = false
    private var bodies: [UUID: (width: Int, body: String, lines: [String])] = [:]
    private var lastTranscript: (key: TerminalHubs.Row.Key?, count: Int) = (nil, 0)
    private var clearing: Task<Void, Never>?
    private var flushing: Task<Void, Never>?
    private var signals: [any DispatchSourceSignal] = []

    /// Where the Hubs are kept. A development build can be pointed at another folder, so trying it never touches the
    /// person's own pairing.
    private static var directory: URL {
        #if NOODLE_DEV_HOOKS
        if let folder = ProcessInfo.processInfo.environment["NOODLE_TERMINAL_HUBS"] { return URL(fileURLWithPath: folder, isDirectory: true) }
        #endif
        return TerminalHubs.standardDirectory
    }

    func run() async {
        console.start()
        let following = Task { await hubs.run() }
        watchWindow()
        redraw()
        for await bytes in console.input() {
            for key in decoder.decode(bytes) {
                handle(key)
                // What a key started, such as a list a command opens, is in place before the next key comes to it.
                await Task.yield()
            }
            flushing?.cancel()
            if decoder.isWaiting {
                // An Escape alone may be the start of a sequence still on its way; a moment's quiet says not.
                flushing = Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { return }
                    for key in self.decoder.flush() { self.handle(key) }
                    self.redraw()
                }
            }
            redraw()
        }
        following.cancel()
        quit()
    }

    func quit() -> Never {
        console.stop()
        exit(0)
    }

    /// Draws everything again when the window changes size, and puts the terminal back when the app is told to stop.
    private func watchWindow() {
        #if os(Windows)
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                if console.measure() { repaint() }
            }
        }
        #else
        func on(_ number: Int32, _ action: @escaping @MainActor () -> Void) {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { action() } }
            source.resume()
            signals.append(source)
        }
        on(SIGWINCH) { [unowned self] in
            if console.measure() { repaint() }
        }
        on(SIGTERM) { [unowned self] in quit() }
        on(SIGHUP) { [unowned self] in quit() }
        #endif
    }

    func repaint() {
        onScreen = []
        console.write("\u{1B}[0m\u{1B}[2J")
        redraw()
    }

    // MARK: Model

    var rows: [TerminalHubs.Row] { hubs.rows }

    /// The bot or group on screen.
    var row: TerminalHubs.Row? {
        guard let current else { return nil }
        return rows.first { $0.id == current }
    }

    func open(_ row: TerminalHubs.Row) {
        current = row.id
        scroll = 0
        selected = nil
        row.chats.shownConversation = row.thread.conversationID
        scheduleRedraw()
    }

    /// The bot or group a name means: the same name, then one starting with it, then one holding it.
    func bestMatch(_ name: String) -> TerminalHubs.Row? {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        let rows = rows
        return rows.first { $0.thread.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? rows.first { $0.thread.name.lowercased().hasPrefix(query.lowercased()) }
            ?? rows.first { $0.thread.name.localizedCaseInsensitiveContains(query) }
    }

    // MARK: Asking

    func tell(_ text: String) {
        notice = text
        clearing?.cancel()
        clearing = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Asks the Hub for something, saying what went wrong if it did.
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { tell(error.localizedDescription) }
        }
    }

    /// Shows a list and waits for the choice. A list or question already open is closed first.
    func pick(_ configured: Picker) async -> Picker.Result {
        closeAsking()
        return await withCheckedContinuation { continuation in
            var shown = configured
            shown.finish = { continuation.resume(returning: $0) }
            picker = shown
        }
    }

    /// The item chosen, or nil when the list was closed.
    func choose(_ title: String, verb: String = "chooses", message: [String] = [], filterable: Bool = true,
                _ items: @escaping @MainActor () -> [Picker.Item]) async -> Picker.Item? {
        let result = await pick(Picker(title: title, verb: verb, message: message, items: items, filterable: filterable,
                                       selection: max(0, items().firstIndex { $0.current } ?? 0)))
        if case .chose(let item) = result { return item }
        return nil
    }

    /// What is checked once Return confirms, or nil when the list was closed.
    func chooseSeveral(_ title: String, checked: Set<String>, _ items: @escaping @MainActor () -> [Picker.Item]) async -> Set<String>? {
        let result = await pick(Picker(title: title, verb: "saves", items: items, checked: checked))
        if case .confirmed(let chosen) = result { return chosen }
        return nil
    }

    /// Asks before something that cannot be taken back. Cancel is chosen until the person chooses otherwise.
    func confirm(_ title: String, _ message: String, button: String) async -> Bool {
        let result = await pick(Picker(title: title, verb: "chooses", message: [message],
                                       items: { [Picker.Item(id: "yes", label: button), Picker.Item(id: "no", label: "Cancel")] },
                                       filterable: false, shortcuts: ["y": "yes", "n": "no"], selection: 1))
        if case .chose(let item) = result { return item.id == "yes" }
        return false
    }

    /// Asks for one field of a form in the message field, with its value so far. Nil when Escape cancels the form.
    func ask(_ title: String, _ label: String, value: String = "", placeholder: String? = nil) async -> String? {
        closeAsking()
        return await withCheckedContinuation { continuation in
            setInput(value)
            prompt = Prompt(title: title, label: label, placeholder: placeholder ?? label) { continuation.resume(returning: $0) }
        }
    }

    /// Asks for a field that cannot be left empty, asking again until it is filled or the form is cancelled.
    func askRequired(_ title: String, _ label: String, value: String = "") async -> String? {
        var value = value
        while true {
            guard let answer = await ask(title, label, value: value) else { return nil }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            tell("\(label) can't be empty.")
            value = ""
        }
    }

    private func closeAsking() {
        if let open = picker {
            picker = nil
            open.finish(.cancelled)
        }
        if let open = prompt {
            prompt = nil
            setInput("")
            open.finish(nil)
        }
    }

    // MARK: Drawing

    /// Draws the screen now, and again whenever anything it showed changes on the Hub.
    func redraw() {
        redrawScheduled = false
        // The conversation on screen stays put as others move up the list; one that left it gives way to the first.
        let listed = rows
        if current == nil || !listed.contains(where: { $0.id == current }), let first = listed.first {
            current = first.id
            first.chats.shownConversation = first.thread.conversationID
            scroll = 0
            selected = nil
        }
        let lines = withObservationTracking { frame() } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRedraw() }
        }
        var output = "\u{1B}[?25l"
        for (index, line) in lines.enumerated() where index >= onScreen.count || onScreen[index] != line {
            // Cleared before it is written: clearing after a line that reaches the last column would take its last
            // character with it.
            output += "\u{1B}[\(index + 1);1H\u{1B}[0m\u{1B}[K" + line + Style.reset
        }
        onScreen = lines
        output += "\u{1B}[\(cursorAt.row);\(cursorAt.column)H\u{1B}[?25h"
        console.write(output)
        redrawScheduled = false
        if let row, row.chats.isUnread(row.thread) { row.chats.markRead(row.thread) }
    }

    func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            if self.redrawScheduled { self.redraw() }
        }
    }

    private var width: Int { max(10, console.columns) }

    /// Every line of the screen, top to bottom: the transcript, the message field between two rules, and under it
    /// a list, or else the status line. A list pushes the transcript up instead of covering it.
    private func frame() -> [String] {
        let height = console.rows
        let listed = rows
        let row = current.flatMap { key in listed.first { $0.id == key } }
        let field = fieldLines(row)
        var below = listLines(listed)
        below = Array(below.prefix(max(1, height - field.count - 3)))
        let available = max(0, height - (2 + field.count + max(1, below.count)))
        let (all, spans) = transcript(row)
        // Scrolled back, the view stays on what it showed as messages arrive under it.
        if scroll > 0, lastTranscript.key == row?.id { scroll += all.count - lastTranscript.count }
        lastTranscript = (row?.id, all.count)
        if reveal, let selected, let span = spans[selected] {
            scroll = Self.scroll(revealing: span, of: all.count, showing: available, from: scroll)
            reveal = false
        }
        scroll = min(max(0, scroll), max(0, all.count - available))
        let end = all.count - scroll
        let shown = all[max(0, end - available)..<end]
        let padding = Array(repeating: "", count: available - shown.count)
        let rule = String(repeating: "─", count: width).styled(.dim)
        cursorAt = cursorPosition(row, fieldTop: available + 2)
        return padding + shown + [rule] + field + [rule] + (below.isEmpty ? [statusLine(listed, row)] : below)
    }

    /// The scroll that shows the lines `span` of a transcript `count` lines long, `available` at a time: as little
    /// moved as can be, the start of the message in view when it is taller than the screen.
    static func scroll(revealing span: Range<Int>, of count: Int, showing available: Int, from scroll: Int) -> Int {
        var scroll = scroll
        if span.lowerBound < count - scroll - available {
            scroll = count - span.lowerBound - available
        } else if span.upperBound > count - scroll {
            scroll = max(0, count - span.upperBound)
            if span.lowerBound < count - scroll - available { scroll = count - span.lowerBound - available }
        }
        return max(0, scroll)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// The conversation's lines, with where each message's lines are.
    private func transcript(_ row: TerminalHubs.Row?) -> ([String], [UUID: Range<Int>]) {
        guard let row else { return ([], [:]) }
        let chats = row.chats, thread = row.thread, width = width
        var lines: [String] = [], spans: [UUID: Range<Int>] = [:]
        if chats.hasEarlier(thread) { lines.append(" ↑ /earlier shows older messages".styled(.dim)) }
        let bodyWidth = max(10, width - 4)
        var previous: Date?
        let calendar = Calendar.current
        for message in chats.messages(of: thread) {
            if previous.map({ !calendar.isDate(message.createdAt, inSameDayAs: $0) }) ?? true {
                if !lines.isEmpty { lines.append("") }
                lines.append(Self.separator(dayName(message.createdAt), width: width))
            }
            previous = message.createdAt
            lines.append("")
            let start = lines.count
            let author = fitted(chats.authorName(of: message, in: thread), to: max(4, width / 2))
            var about = Self.time.string(from: message.createdAt)
            if let delivery = chats.delivery(of: message) { about += " · " + delivery }
            if selected == message.id {
                lines.append(" " + fitted(" \(author)  \(about) ", to: width - 1).styled([.inverse, .bold]))
            } else {
                lines.append(" " + author.styled([.bold, message.author == .you ? .person : .bot]) + "  "
                             + fitted(about, to: max(0, width - columns(of: author) - 3)).styled(.dim))
            }
            if !message.body.isEmpty { lines += body(of: message, width: bodyWidth).map { "   " + $0 } }
            if let reason = chats.unsent[message.id] ?? nil {
                lines += wrapped(reason, width: bodyWidth).map { "   " + $0.styled(.red) }
            }
            for attachment in message.attachments {
                let text = attachment.url.map { "🔗 " + (attachment.card?.title ?? $0.absoluteString) }
                    ?? "📎 \(attachment.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))"
                lines.append("   " + fitted(text, to: bodyWidth).styled(.dim))
            }
            if !message.reactions.isEmpty {
                lines.append("   " + fitted(message.reactions.map(\.emoji).joined(separator: " "), to: bodyWidth))
            }
            spans[message.id] = start..<lines.count
        }
        return (lines, spans)
    }

    private static func separator(_ text: String, width: Int) -> String {
        let label = " \(fitted(text, to: max(1, width - 8))) "
        let side = max(1, (width - 2 - columns(of: label)) / 2)
        return (" " + String(repeating: "─", count: side) + label + String(repeating: "─", count: side)).styled(.dim)
    }

    /// A message's words as drawn, worked out once for each width and wording.
    private func body(of message: LinkMessage, width: Int) -> [String] {
        if let kept = bodies[message.id], kept.width == width, kept.body == message.body { return kept.lines }
        let lines = MarkdownText.lines(message.body, width: width)
        bodies[message.id] = (width, message.body, lines)
        return lines
    }

    /// The list under the message field: an open list, or suggestions for what is typed.
    private func listLines(_ listed: [TerminalHubs.Row]) -> [String] {
        if let picker {
            var lines = picker.message.flatMap { wrapped($0, width: width - 4).map { "   " + $0 } }
            let items = picker.shown()
            if items.isEmpty {
                lines.append("   Nothing matches".styled(.dim))
            } else {
                let checked = picker.checked
                let marks = checked != nil || items.contains { $0.current }
                lines += Self.list(items.map { item in
                    let mark = checked.map { $0.contains(item.id) ? "[x] " : "[ ] " } ?? (marks ? (item.current ? "✓ " : "  ") : "")
                    return (mark + item.label, item.detail)
                }, selection: picker.selection, width: width)
            }
            return lines
        }
        let options = suggestions(listed)
        return options.isEmpty ? [] : Self.list(options.map { ($0.label, $0.detail) }, selection: suggestion, width: width)
    }

    static let listHeight = 10

    /// Names in one column and what they are in another, dim, the chosen row in the accent colour across both, at
    /// most ten rows around the choice with how many more there are above and below.
    static func list(_ entries: [(String, String)], selection: Int, width: Int) -> [String] {
        let nameWidth = min(32, max(1, entries.map { columns(of: printable($0.0)) }.max() ?? 0), max(1, width - 8))
        let window = listWindow(count: entries.count, selection: selection, height: listHeight)
        var lines: [String] = []
        if window.lowerBound > 0 { lines.append("   ↑ \(window.lowerBound) more".styled(.dim)) }
        for index in window {
            let (name, detail) = entries[index]
            let cell = padded(name, to: nameWidth)
            let about = fitted(detail, to: max(0, width - nameWidth - 8))
            lines.append(index == selection
                ? (" › " + cell + "    " + about).styled(.accent)
                : "   " + cell + "    " + about.styled(.dim))
        }
        let below = entries.count - window.upperBound
        if below > 0 { lines.append("   ↓ \(below) more".styled(.dim)) }
        return lines
    }

    private let promptWidth = 3
    private static let promptMark = " › ".styled(.accent)

    /// The message field, wrapped, at most five lines, showing the part around the cursor.
    private func fieldLines(_ row: TerminalHubs.Row?) -> [String] {
        let fieldWidth = max(1, width - promptWidth - 1)
        if let picker {
            // While a list is open, what is typed narrows it.
            let keys = "↑↓ choose" + (picker.checked != nil ? " · Space toggles" : "") + " · Return \(picker.verb) · Esc closes"
            let hint = picker.filterable ? "Type to narrow \(picker.title) · " + keys : "\(picker.title) · " + keys
            return [Self.promptMark + (picker.query.isEmpty ? fitted(hint, to: fieldWidth).styled(.dim) : fitted(picker.query, to: fieldWidth))]
        }
        if input.isEmpty {
            let hint: String
            if let prompt {
                hint = prompt.placeholder
            } else if hubs.chats.isEmpty {
                hint = "Paste an invitation link or code to join a Hub"
            } else if let row {
                hint = row.chats.composerUnavailableReason(for: row.thread) ?? "Message \(row.thread.name), or / for commands"
            } else {
                hint = "/ for commands"
            }
            return [Self.promptMark + fitted(hint, to: fieldWidth).styled(.dim)]
        }
        let lines = TerminalScreen.fieldLines(input, width: fieldWidth)
        let visible = visibleLines(lines)
        return visible.map { range in
            (range.lowerBound == 0 ? Self.promptMark : "   ") + printable(String(input[range]))
        }
    }

    private func visibleLines(_ lines: [Range<Int>]) -> ArraySlice<Range<Int>> {
        let at = fieldLine(of: cursor, in: lines)
        let first = max(0, min(at - 4, lines.count - 5))
        return lines[first..<min(lines.count, first + 5)]
    }

    private func cursorPosition(_ row: TerminalHubs.Row?, fieldTop: Int) -> (row: Int, column: Int) {
        if let picker { return (fieldTop, promptWidth + 1 + min(columns(of: printable(picker.query)), width - promptWidth - 1)) }
        let fieldWidth = max(1, width - promptWidth - 1)
        guard !input.isEmpty else { return (fieldTop, promptWidth + 1) }
        let lines = TerminalScreen.fieldLines(input, width: fieldWidth)
        let visible = visibleLines(lines)
        let at = fieldLine(of: cursor, in: lines)
        let line = lines[at]
        let column = columns(of: printable(String(input[line.lowerBound..<cursor]))) + promptWidth + 1
        return (fieldTop + (at - visible.startIndex), min(column, width))
    }

    static func phaseName(_ phase: LinkBotPhase) -> String {
        switch phase {
        case .offline: "offline"
        case .starting: "starting"
        case .ready: "ready"
        case .working: "working…"
        case .failed: "needs a kick"
        }
    }

    /// The bot or group on screen, its Hub and what its bot is doing, then the others waiting to be read; or the
    /// form being filled in; or a notice for a while.
    private func statusLine(_ listed: [TerminalHubs.Row], _ row: TerminalHubs.Row?) -> String {
        if let notice { return (" " + fitted(notice, to: width - 1)).styled(.accent) }
        if let prompt {
            let title = " " + fitted(prompt.title, to: width / 2)
            return title.styled(.bold) + ("  " + fitted("\(prompt.label) · Return accepts · Esc cancels", to: max(0, width - columns(of: title) - 2))).styled(.dim)
        }
        guard let row else {
            let state = hubs.chats.isEmpty ? "No Hub yet: paste an invitation link or code"
                : hubs.isLoaded ? "No bots or groups yet: /new bot" : "Connecting…"
            return " Noodle".styled(.bold) + ("  " + fitted(state, to: max(0, width - 9))).styled(.dim)
        }
        var parts = [row.chats.isConnected ? row.chats.hubName : row.chats.hubName + " (reconnecting)"]
        switch row.thread {
        case .bot(let bot):
            if let owner = bot.owner { parts.append("\(owner)'s bot") }
            if let pause = bot.pause { parts.append(pause.shown()) } else { parts += [bot.phase.map(Self.phaseName), bot.status].compactMap { $0 } }
        case .group(let group):
            parts.append(row.chats.members(of: group).map(\.draft.name).joined(separator: ", "))
        }
        let unread = listed.filter { $0.id != row.id && $0.chats.countsAsUnread($0.thread) }
        if !unread.isEmpty {
            parts.append("\(unread.count) unread: " + unread.prefix(3).map(\.thread.name).joined(separator: ", ") + (unread.count > 3 ? "…" : ""))
        }
        if scroll > 0 { parts.append("scrolled up, End returns") }
        parts.append("/help")
        let name = " " + fitted(row.thread.name, to: width / 2)
        return name.styled(.bold) + ("  " + fitted(parts.filter { !$0.isEmpty }.joined(separator: " · "), to: max(0, width - columns(of: name) - 2))).styled(.dim)
    }

    // MARK: Suggestions

    struct Suggestion {
        var label: String
        var detail: String
        var completion: String
        var runs: Bool
    }

    /// What the message field offers while a command is typed: commands and bots and groups by name, or what may
    /// follow a command's name.
    func suggestions(_ listed: [TerminalHubs.Row]) -> [Suggestion] {
        guard picker == nil, prompt == nil, input.first == "/", !input.contains("\n") else { return [] }
        let body = String(input.dropFirst())
        if let space = body.firstIndex(of: " ") {
            let name = body[..<space].lowercased(), rest = String(body[body.index(after: space)...])
            guard let command = commands.first(where: { $0.name == name }), command.isAvailable(), let options = command.options else { return [] }
            return narrowed(options(), by: rest, name: { $0.label }, detail: { $0.detail }).map {
                Suggestion(label: $0.label, detail: $0.detail, completion: "/\(name) \($0.label)", runs: true)
            }
        }
        let query = body.lowercased()
        let names = commands.filter { (query.isEmpty || $0.name.hasPrefix(query)) && $0.isAvailable() }.map {
            Suggestion(label: "/" + $0.name + ($0.argument.map { " " + $0 } ?? ""), detail: $0.summary,
                       completion: "/" + $0.name + ($0.fills ? " " : ""), runs: !$0.fills)
        }
        // A name straight after the slash finds bots and groups too.
        let threads = query.isEmpty ? [] : listed.filter { $0.thread.name.localizedCaseInsensitiveContains(query) }.prefix(5).map {
            Suggestion(label: $0.thread.name, detail: Self.kind(of: $0, among: hubs), completion: "/switch " + $0.thread.name, runs: true)
        }
        return names + threads
    }

    /// "bot" or "group", with its Hub when there are several.
    static func kind(of row: TerminalHubs.Row, among hubs: TerminalHubs) -> String {
        (row.thread.group != nil ? "group" : "bot") + (hubs.chats.count > 1 ? " · " + row.chats.hubName : "")
    }

    // MARK: Keys

    func handle(_ key: Key) {
        if picker != nil { return handlePicker(key) }
        if notice != nil, key != .escape {
            clearing?.cancel()
            notice = nil
        }
        let options = suggestions(rows)
        if !options.isEmpty { suggestion = min(suggestion, options.count - 1) }
        switch key {
        case .text(let text):
            // A message being written leaves the chosen one; a command keeps it, to act on it.
            if selected != nil, !(String(input) + text).hasPrefix("/") { selected = nil }
            insert(text)
        case .paste(let text):
            if selected != nil, !(String(input) + text).hasPrefix("/") { selected = nil }
            insert(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        case .enter:
            if let open = prompt {
                let text = String(input)
                prompt = nil
                setInput("")
                open.finish(text)
            } else if options.indices.contains(suggestion) {
                let option = options[suggestion]
                if option.runs { submit(option.completion) } else { setInput(option.completion) }
            } else {
                submit(String(input))
            }
        case .tab:
            if options.indices.contains(suggestion) { setInput(options[suggestion].completion) }
        case .up:
            if !options.isEmpty { suggestion = max(0, suggestion - 1) } else if input.isEmpty, prompt == nil { chooseMessage(-1) } else { moveLine(-1) }
        case .down:
            if !options.isEmpty { suggestion = min(options.count - 1, suggestion + 1) } else if input.isEmpty, prompt == nil { chooseMessage(1) } else { moveLine(1) }
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(input.count, cursor + 1)
        case .home, .control("a"): cursor = 0
        case .end, .control("e"):
            if input.isEmpty || cursor == input.count {
                scroll = 0
                selected = nil
            }
            cursor = input.count
        case .backspace:
            if cursor > 0 { input.remove(at: cursor - 1); cursor -= 1; suggestion = 0 }
        case .delete:
            if cursor < input.count { input.remove(at: cursor) }
        case .control("d"):
            // Control-D deletes forward, as in a shell, and quits from an empty field.
            if !input.isEmpty { if cursor < input.count { input.remove(at: cursor) } } else if prompt == nil { quit() }
        case .control("u"): input.removeSubrange(0..<cursor); cursor = 0; suggestion = 0
        case .control("w"):
            var start = cursor
            while start > 0, input[start - 1] == " " { start -= 1 }
            while start > 0, input[start - 1] != " " { start -= 1 }
            input.removeSubrange(start..<cursor); cursor = start; suggestion = 0
        case .control("c"):
            if prompt != nil { closeAsking() } else if input.isEmpty { quit() } else { setInput("") }
        case .control("j"): insert("\n")
        case .control("l"): repaint()
        case .control("o"): if prompt == nil { nextSpace() }
        case .escape:
            if prompt != nil { closeAsking(); return }
            clearing?.cancel()
            notice = nil
            selected = nil
            if !options.isEmpty { setInput("") }
        case .pageUp: scroll += max(1, console.rows - 8)
        case .pageDown: scroll = max(0, scroll - max(1, console.rows - 8))
        case .wheelUp: scroll += 3
        case .wheelDown: scroll = max(0, scroll - 3)
        default: break
        }
    }

    func insert(_ text: String) {
        input.insert(contentsOf: text.replacingOccurrences(of: "\t", with: "    "), at: cursor)
        cursor += text.replacingOccurrences(of: "\t", with: "    ").count
        suggestion = 0
    }

    func setInput(_ text: String) {
        input = Array(text)
        cursor = input.count
        suggestion = 0
    }

    /// Up and Down in a field of several lines go from line to line, keeping the column where they can.
    private func moveLine(_ step: Int) {
        let lines = TerminalScreen.fieldLines(input, width: max(1, width - promptWidth - 1))
        let at = fieldLine(of: cursor, in: lines), next = at + step
        guard lines.indices.contains(next) else { return }
        let column = columns(of: String(input[lines[at].lowerBound..<cursor]))
        var position = lines[next].lowerBound, used = 0
        while position < lines[next].upperBound, used + columns(of: input[position]) <= column {
            used += columns(of: input[position]); position += 1
        }
        cursor = position
    }

    /// Up from the newest message chooses it, then goes back through them; Down past the newest leaves them.
    private func chooseMessage(_ step: Int) {
        guard let row else { return }
        let messages = row.chats.messages(of: row.thread)
        guard !messages.isEmpty else { return }
        guard let selected, let index = messages.firstIndex(where: { $0.id == selected }) else {
            if step < 0 { self.selected = messages.last?.id }
            return
        }
        let next = index + step
        if next >= messages.count {
            self.selected = nil
            scroll = 0
        } else {
            self.selected = messages[max(0, next)].id
        }
    }

    func submit(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        setInput("")
        // Two slashes send a message that starts with one.
        if line.hasPrefix("//") { return send(String(line.dropFirst())) }
        if let command = SlashCommand(line) {
            if let match = commands.first(where: { $0.name == command.name }) {
                guard match.isAvailable() else { return tell(Self.unavailable(match.name)) }
                return match.run(command.rest)
            }
            if let match = bestMatch(String(line.dropFirst())) { return open(match) }
            return tell("There's no /\(command.name) command, bot or group. /help lists the commands.")
        }
        // Before any Hub, what is pasted is the invitation.
        if hubs.chats.isEmpty { return join(line) }
        selected = nil
        send(line)
    }

    private func handlePicker(_ key: Key) {
        guard var open = picker else { return }
        let items = open.shown()
        func finish(_ result: Picker.Result) {
            picker = nil
            open.finish(result)
        }
        switch key {
        case .escape, .control("c"):
            return finish(.cancelled)
        case .text(" ") where open.checked != nil:
            if items.indices.contains(open.selection) {
                let id = items[open.selection].id
                if open.checked!.contains(id) { open.checked!.remove(id) } else { open.checked!.insert(id) }
            }
        case .text(let text):
            if let id = open.shortcuts[text.lowercased()], let item = items.first(where: { $0.id == id }) { return finish(.chose(item)) }
            guard open.filterable else { break }
            open.query += text.replacingOccurrences(of: "\n", with: " ")
            open.selection = 0
        case .paste(let text) where open.filterable:
            open.query += printable(text)
            open.selection = 0
        case .backspace:
            if !open.query.isEmpty { open.query.removeLast() }
            open.selection = 0
        case .control("u"):
            open.query = ""
            open.selection = 0
        case .up: open.selection = max(0, open.selection - 1)
        case .down: open.selection = min(max(0, items.count - 1), open.selection + 1)
        case .pageUp: open.selection = max(0, open.selection - Self.listHeight)
        case .pageDown: open.selection = min(max(0, items.count - 1), open.selection + Self.listHeight)
        case .enter:
            if let checked = open.checked { return finish(.confirmed(checked)) }
            guard items.indices.contains(open.selection) else { return }
            return finish(.chose(items[open.selection]))
        case .wheelUp: scroll += 3
        case .wheelDown: scroll = max(0, scroll - 3)
        default: break
        }
        picker = open
    }

    // MARK: Spaces

    private func nextSpace() {
        let spaces = hubs.spaces
        guard spaces.count > 1, let index = spaces.firstIndex(of: hubs.space) else { return }
        hubs.space = spaces[(index + 1) % spaces.count]
        tell("Showing \(hubs.name(of: hubs.space)).")
    }
}
