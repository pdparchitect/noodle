import Foundation

/// A message body cut at its Markdown tables, so each part can be drawn on its own.
public enum MessageSegment: Equatable, Sendable {
    case text(String)
    case table(MessageTable)

    public static func split(_ body: String) -> [MessageSegment] {
        // Most messages have no table; keep them exactly as written.
        guard body.contains("|"), body.contains("-") else { return body.isEmpty ? [] : [.text(body)] }
        let lines = body.components(separatedBy: "\n")
        var segments: [MessageSegment] = []
        var prose: [String] = []
        var inFence = false
        var index = 0

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { segments.append(.text(text)) }
            prose = []
        }

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, index + 1 < lines.count, line.contains("|"),
               let alignments = MessageTable.alignments(lines[index + 1]) {
                let header = MessageTable.cells(line)
                if header.count == alignments.count {
                    var rows: [[String]] = []
                    index += 2
                    while index < lines.count, lines[index].contains("|"),
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        let row = MessageTable.cells(lines[index])
                        rows.append(Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count)))
                        index += 1
                    }
                    flushProse()
                    segments.append(.table(MessageTable(header: header, alignments: alignments, rows: rows)))
                    continue
                }
            }
            prose.append(line)
            index += 1
        }
        flushProse()
        // A body that only looked like it might hold a table stays untouched, whitespace included.
        return segments.contains { if case .table = $0 { true } else { false } } ? segments : [.text(body)]
    }
}

public struct MessageTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing, automatic }

    public var header: [String]
    public var alignments: [Alignment]
    public var rows: [[String]]

    /// Rows a long table shows in the transcript.
    public static let foldedRowCount = 6

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    /// Folding only pays off when it hides at least three rows.
    public var folds: Bool { rows.count > Self.foldedRowCount + 2 }

    /// The column's alignment, with numbers going trailing unless the table chose otherwise.
    public func alignment(_ column: Int) -> Alignment {
        guard alignments[column] == .automatic else { return alignments[column] }
        let numeric = rows.allSatisfy { row in
            let text = Self.plainText(row[column])
            return text.isEmpty || Self.number(text) != nil
        }
        return numeric ? .trailing : .leading
    }

    /// Numbers compare as numbers and come before text; text compares in Finder order.
    public func sorted(by sort: MessageTableSort?) -> MessageTable {
        var sorted = self
        sorted.rows = rowOrder(by: sort).map { rows[$0] }
        return sorted
    }

    /// Positions of the rows in sorted order, so views can keep each row's identity.
    public func rowOrder(by sort: MessageTableSort?) -> [Int] {
        guard let sort else { return Array(rows.indices) }
        func less(_ a: String, _ b: String) -> Bool {
            switch (Self.number(a), Self.number(b)) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.localizedStandardCompare(b) == .orderedAscending
            }
        }
        let keys = rows.map { Self.plainText($0[sort.column]) }
        return rows.indices.sorted { sort.ascending ? less(keys[$0], keys[$1]) : less(keys[$1], keys[$0]) }
    }

    /// The table as shown, without Markdown, as RFC 4180 CSV.
    public var csv: String {
        ([header] + rows).map { row in
            row.map { cell in
                let text = Self.plainText(cell)
                return text.contains(where: { ",\"\n\r".contains($0) })
                    ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    public static func plainText(_ cell: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: cell, options: options)).map { String($0.characters) } ?? cell
    }

    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " $€£%+×x"))
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: ""))
    }

    static func cells(_ line: String) -> [String] {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text = text.dropLast() }
        var cells: [String] = [], current = "", escaped = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(current); current = "" }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func alignments(_ line: String) -> [Alignment]? {
        guard line.contains("-") else { return nil }
        var result: [Alignment] = []
        for cell in cells(line) {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            case (true, false): result.append(.leading)
            case (false, false): result.append(.automatic)
            }
        }
        return result
    }
}

/// How a table is sorted on screen; it is never stored with the message.
public struct MessageTableSort: Equatable, Sendable {
    public var column: Int
    public var ascending: Bool

    public init(column: Int, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// Clicking a header sorts ascending, then descending, then back to the table's own order.
    public static func next(after current: MessageTableSort?, column: Int) -> MessageTableSort? {
        guard let current, current.column == column else { return MessageTableSort(column: column, ascending: true) }
        return current.ascending ? MessageTableSort(column: column, ascending: false) : nil
    }
}
