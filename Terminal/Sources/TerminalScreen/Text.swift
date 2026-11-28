import Foundation
import HubLink

// MARK: Widths

/// Columns a character takes in a terminal: two for wide East Asian characters and most emoji, none for controls.
public func columns(of character: Character) -> Int {
    guard let scalar = character.unicodeScalars.first else { return 0 }
    let value = scalar.value
    if isControl(scalar) { return 0 }
    if scalar.properties.isEmojiPresentation || character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
    switch value {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
         0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
        return 2
    default:
        return 1
    }
}

public func columns(of text: String) -> Int { text.reduce(0) { $0 + columns(of: $1) } }

private func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7F..<0xA0).contains(scalar.value)
}

/// `text` as it can be drawn: tabs as spaces, and no control characters, so nothing a Hub or a paste sends can
/// move the cursor, retitle the window or reach the clipboard. Line breaks stay only when `lines` is set.
public func printable(_ text: String, lines: Bool = false) -> String {
    guard text.unicodeScalars.contains(where: isControl) else { return text }
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for character in text {
        if character == "\t" { result += "    "; continue }
        if character == "\n" || character == "\r\n" { result += lines ? "\n" : " "; continue }
        if let first = character.unicodeScalars.first, isControl(first) { continue }
        result.append(character)
    }
    return result
}

/// `text` cut to `width` columns, with an ellipsis when it had to be cut.
public func fitted(_ text: String, to width: Int) -> String {
    let text = printable(text)
    guard width > 0 else { return "" }
    guard columns(of: text) > width else { return text }
    var result = "", used = 0
    for character in text {
        let size = columns(of: character)
        if used + size > width - 1 { break }
        result.append(character); used += size
    }
    return result + "…"
}

/// `text` fitted to `width` columns and filled out with spaces to it.
public func padded(_ text: String, to width: Int) -> String {
    let cell = fitted(text, to: width)
    return cell + String(repeating: " ", count: max(0, width - columns(of: cell)))
}

/// `text` broken into lines of at most `width` columns, at spaces where it can, keeping its own line breaks.
public func wrapped(_ text: String, width: Int) -> [String] {
    printable(text, lines: true).split(separator: "\n", omittingEmptySubsequences: false).flatMap { paragraph in
        wrap(paragraph.map { Cell($0) }, width: width).map { String($0.map(\.character)) }
    }
}

// MARK: Styles

/// How a piece of text is drawn.
public struct Style: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = Style(rawValue: 1 << 0)
    public static let dim = Style(rawValue: 1 << 1)
    public static let italic = Style(rawValue: 1 << 2)
    public static let underline = Style(rawValue: 1 << 3)
    public static let strikethrough = Style(rawValue: 1 << 4)
    public static let inverse = Style(rawValue: 1 << 5)
    /// Yellow: what is chosen, notices, code and links.
    public static let accent = Style(rawValue: 1 << 6)
    /// Cyan: the person.
    public static let person = Style(rawValue: 1 << 7)
    /// Magenta: bots.
    public static let bot = Style(rawValue: 1 << 8)
    public static let red = Style(rawValue: 1 << 9)

    /// The escape sequence that sets exactly this style, from plain.
    public var code: String {
        var parts = ["0"]
        if contains(.bold) { parts.append("1") }
        if contains(.dim) { parts.append("2") }
        if contains(.italic) { parts.append("3") }
        if contains(.underline) { parts.append("4") }
        if contains(.inverse) { parts.append("7") }
        if contains(.strikethrough) { parts.append("9") }
        if contains(.red) { parts.append("31") } else if contains(.accent) { parts.append("33") }
        else if contains(.bot) { parts.append("35") } else if contains(.person) { parts.append("36") }
        return "\u{1B}[" + parts.joined(separator: ";") + "m"
    }

    public static let reset = "\u{1B}[0m"
}

extension String {
    /// The text in a style, back to plain after it.
    public func styled(_ style: Style) -> String { style.isEmpty ? self : style.code + self + Style.reset }
}

/// A character and its style.
public struct Cell: Equatable, Sendable {
    public var character: Character
    public var style: Style

    public init(_ character: Character, _ style: Style = []) {
        self.character = character
        self.style = style
    }
}

func cells(_ text: String, _ style: Style = []) -> [Cell] { printable(text).map { Cell($0, style) } }

/// Cells as text for the terminal, the style changed only where it changes.
public func drawn(_ cells: [Cell]) -> String {
    var output = "", current: Style = []
    for cell in cells {
        if cell.style != current { output += cell.style.code; current = cell.style }
        output.append(cell.character)
    }
    if !current.isEmpty { output += Style.reset }
    return output
}

/// Cells broken into lines of at most `width` columns, at spaces where it can: spaces where a line breaks are
/// left out, those that start it kept, and a word longer than a line is cut where it reaches the edge.
func wrap(_ cells: [Cell], width: Int) -> [[Cell]] {
    guard width > 0 else { return [] }
    var lines: [[Cell]] = []
    var line: [Cell] = [], used = 0
    var index = 0
    while index < cells.count {
        var wordStart = index
        while wordStart < cells.count, cells[wordStart].character == " " { wordStart += 1 }
        var wordEnd = wordStart
        while wordEnd < cells.count, cells[wordEnd].character != " " { wordEnd += 1 }
        let spaces = cells[index..<wordStart], word = cells[wordStart..<wordEnd]
        let wordWidth = word.reduce(0) { $0 + columns(of: $1.character) }
        if used + spaces.count + wordWidth <= width {
            line += spaces; line += word; used += spaces.count + wordWidth
        } else if wordWidth <= width {
            if !line.isEmpty { lines.append(line) }
            line = Array(word); used = wordWidth
        } else {
            if used + spaces.count < width { line += spaces; used += spaces.count } else if !line.isEmpty { lines.append(line); line = []; used = 0 }
            for cell in word {
                let size = columns(of: cell.character)
                if used + size > width { lines.append(line); line = []; used = 0 }
                line.append(cell); used += size
            }
        }
        index = wordEnd
    }
    lines.append(line)
    return lines
}

/// Cells wrapped after a first-line prefix, later lines starting with `hanging` instead, so a list item's
/// or quote's lines line up.
func wrap(_ content: [Cell], width: Int, prefix: [Cell], hanging: [Cell]) -> [[Cell]] {
    let indent = prefix.reduce(0) { $0 + columns(of: $1.character) }
    return wrap(content, width: max(1, width - indent)).enumerated().map { index, line in (index == 0 ? prefix : hanging) + line }
}

// MARK: Markdown

/// The markdown bots write, as far as a terminal shows it: headings and strong text in bold, emphasis in italics,
/// code in the accent colour, links underlined with where they go, lists with bullets, quotes with a bar, and
/// code blocks dimmed.
public enum MarkdownText {
    /// The message's lines, wrapped to `width`, ready to draw.
    public static func lines(_ body: String, width: Int) -> [String] {
        var lines: [[Cell]] = []
        var inCode = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = printable(String(raw))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                lines += wrap(cells(line, .dim), width: width)
            } else if trimmed.isEmpty {
                lines.append([])
            } else if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).count == 1, "-*_".contains(trimmed.first!) {
                lines.append(cells(String(repeating: "─", count: min(width, 20)), .dim))
            } else if let heading = trimmed.firstMatch(of: /^#{1,6}\s+(.*)$/) {
                lines += wrap(inline(String(heading.1), base: .bold), width: width)
            } else if let item = line.firstMatch(of: /^(\s*)[-*+]\s+(.*)$/) {
                let marker = String(item.1) + "• "
                lines += wrap(inline(String(item.2)), width: width, prefix: cells(marker),
                              hanging: cells(String(repeating: " ", count: columns(of: marker))))
            } else if let item = line.firstMatch(of: /^(\s*)(\d+[.)])\s+(.*)$/) {
                let marker = "\(item.1)\(item.2) "
                lines += wrap(inline(String(item.3)), width: width, prefix: cells(marker),
                              hanging: cells(String(repeating: " ", count: columns(of: marker))))
            } else if let quote = trimmed.firstMatch(of: /^>\s?(.*)$/) {
                lines += wrap(inline(String(quote.1), base: .dim), width: width, prefix: cells("│ ", .dim), hanging: cells("│ ", .dim))
            } else {
                lines += wrap(inline(line), width: width)
            }
        }
        return lines.map(drawn)
    }

    /// A line's inline markdown as styled cells. A link shows its words, then where it goes when that differs.
    static func inline(_ text: String, base: Style = []) -> [Cell] {
        var result: [Cell] = []
        var openLink: String?, linkWords = ""
        func closeLink() {
            // Where it goes is left out when the words already say it.
            if let link = openLink, linkWords != link, "mailto:" + linkWords != link, let shown = shownDestination(link) {
                result += cells(" (\(shown))", base.union(.dim))
            }
            openLink = nil
            linkWords = ""
        }
        for run in InlineMarkdown.runs(text) {
            if run.link != openLink {
                closeLink()
                openLink = run.link
            }
            var style = base
            if run.strong { style.insert(.bold) }
            if run.emphasis { style.insert(.italic) }
            if run.strikethrough { style.insert(.strikethrough) }
            if run.code { style.insert(.accent) }
            if run.link != nil { style.formUnion([.underline, .accent]); linkWords += run.text }
            result += cells(run.text, style)
        }
        closeLink()
        return result
    }

    private static func shownDestination(_ link: String) -> String? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return link
    }

    /// The web links a message holds, in order, each once: its markdown links and the addresses written out.
    public static func links(in body: String) -> [URL] {
        var seen: Set<String> = [], found: [URL] = []
        func add(_ text: String) {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil,
                  seen.insert(url.absoluteString).inserted else { return }
            found.append(url)
        }
        var inCode = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            for run in InlineMarkdown.runs(String(line)) {
                if let link = run.link { add(link); continue }
                guard !run.code else { continue }
                for match in run.text.matches(of: /https?:\/\/[^\s<>()\[\]"'`]+/) {
                    // Punctuation that ends the sentence is not part of the address.
                    add(String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")))
                }
            }
        }
        return found
    }
}

// MARK: Lists

/// Which rows of a list of `count` show in `height` rows, keeping the chosen one in view and near the middle.
public func listWindow(count: Int, selection: Int, height: Int) -> Range<Int> {
    let first = max(0, min(selection - height / 2, count - height))
    return first..<min(count, first + height)
}

/// The entries whose name has the words typed, then those whose description has them, each in their order.
public func narrowed<Entry>(_ entries: [Entry], by query: String, name: (Entry) -> String, detail: (Entry) -> String) -> [Entry] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return entries }
    func has(_ text: String) -> Bool {
        let text = text.lowercased()
        return words.allSatisfy { text.contains($0) }
    }
    let byName = entries.filter { has(name($0)) }
    let byDetail = entries.filter { !has(name($0)) && has(name($0) + " " + detail($0)) }
    return byName + byDetail
}

// MARK: The message field

/// Where each line of the message field starts and ends in what is typed, breaking at new lines and at the edge.
public func fieldLines(_ input: [Character], width: Int) -> [Range<Int>] {
    var lines: [Range<Int>] = []
    var start = 0, used = 0
    let width = max(1, width)
    for (index, character) in input.enumerated() {
        if character == "\n" {
            lines.append(start..<index); start = index + 1; used = 0; continue
        }
        let size = columns(of: character)
        if used + size > width, index > start { lines.append(start..<index); start = index; used = 0 }
        used += size
    }
    lines.append(start..<input.count)
    return lines
}

/// The line of the field the cursor is on.
public func fieldLine(of cursor: Int, in lines: [Range<Int>]) -> Int {
    lines.lastIndex { $0.lowerBound <= cursor } ?? 0
}

// MARK: Commands

/// A line typed as a command: `/name` and what follows it.
public struct SlashCommand: Equatable, Sendable {
    public var name: String
    public var rest: String

    /// Nil for a line that is not a command. The name is matched without regard to case.
    public init?(_ line: String) {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/") else { return nil }
        let body = line.dropFirst()
        name = String(body.prefix { !$0.isWhitespace }).lowercased()
        rest = body.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The file a path typed or dropped in names, as a shell would read it: `~` for the home folder, quotes
/// around it and backslashes before spaces taken off. Nil when nothing was typed.
public func typedPath(_ typed: String, home: String) -> String? {
    var path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.count >= 2, let first = path.first, first == path.last, first == "'" || first == "\"" {
        path = String(path.dropFirst().dropLast())
    } else {
        path = path.replacingOccurrences(of: "\\ ", with: " ")
    }
    guard !path.isEmpty else { return nil }
    if path == "~" { return home }
    if path.hasPrefix("~/") { return (home.hasSuffix("/") ? String(home.dropLast()) : home) + path.dropFirst() }
    return path
}

// MARK: Days

/// The day a stretch of messages is from, as a line between days names it: "Today", "Yesterday", the weekday
/// within the last week, then the date, with the year only when it differs.
public func dayName(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case 0: return "Today"
    case 1: return "Yesterday"
    case 2..<7: return date.formatted(style.weekday(.wide))
    default:
        return calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
            : date.formatted(style.day().month(.abbreviated).year())
    }
}
