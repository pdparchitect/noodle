import Foundation

/// A Markdown file read as a document: its headings, paragraphs, lists, quotes, code and tables, in order.
public struct MarkdownDocument: Sendable {
    public enum Block: Sendable, Equatable {
        case heading(Int, AttributedString)
        case paragraph(AttributedString)
        case listItem(ListItem)
        case quote(AttributedString)
        case code(language: String?, text: String)
        case table(Table)
        case rule
    }

    public struct ListItem: Sendable, Equatable {
        public enum Task: Sendable, Equatable { case open, done }
        /// "•", or the item's number written as "3."; empty for a later paragraph of the same item.
        public let marker: String
        /// 1 for a top-level item, 2 for one inside it, and so on.
        public let depth: Int
        /// A GitHub task: an item begun with "[ ]" or "[x]".
        public let task: Task?
        public let text: AttributedString
    }

    public struct Table: Sendable, Equatable {
        public enum Alignment: Sendable, Equatable { case leading, center, trailing }
        public let alignments: [Alignment]
        public let header: [AttributedString]
        public let rows: [[AttributedString]]
    }

    public let blocks: [Block]

    public init(_ text: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        blocks = Self.blocks(of: (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    /// Told apart by name or media type, as files arrive with all sorts of both.
    public static func isMarkdown(name: String, mediaType: String) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mkdn"].contains((name as NSString).pathExtension.lowercased()) ||
            ["text/markdown", "text/x-markdown"].contains(mediaType.lowercased())
    }

    private static func blocks(of parsed: AttributedString) -> [Block] {
        var blocks: [Block] = []
        var pending: (leaf: PresentationIntent.IntentType?, intent: PresentationIntent?, text: AttributedString)?
        var table: TableBuilder?
        var listItemsSeen: Set<Int> = []

        func finishTable() {
            if let built = table?.table { blocks.append(.table(built)) }
            table = nil
        }
        func flush() {
            guard let (leaf, intent, text) = pending else { return }
            pending = nil
            let containers = intent?.components.dropFirst() ?? []
            switch leaf?.kind {
            case .tableCell(let column):
                guard let tableIntent = containers.first(where: { if case .table = $0.kind { true } else { false } }),
                      case .table(let columns) = tableIntent.kind else { return }
                if table?.id != tableIntent.identity {
                    finishTable()
                    table = TableBuilder(id: tableIntent.identity, alignments: columns.map(Table.Alignment.init))
                }
                let row = containers.first { if case .tableRow = $0.kind { true } else if case .tableHeaderRow = $0.kind { true } else { false } }
                table?.add(text, column: column, row: row)
                return
            default:
                finishTable()
            }
            switch leaf?.kind {
            case .header(let level):
                blocks.append(.heading(level, text))
            case .codeBlock(let language):
                var code = String(text.characters)
                while code.hasSuffix("\n") { code.removeLast() }
                blocks.append(.code(language: language.flatMap { $0.isEmpty ? nil : $0 }, text: code))
            case .thematicBreak:
                blocks.append(.rule)
            default:
                if let item = containers.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
                   case .listItem(let ordinal) = containers[item].kind {
                    let ordered = containers.index(after: item) < containers.endIndex &&
                        { if case .orderedList = containers[containers.index(after: item)].kind { true } else { false } }()
                    let depth = containers.filter { if case .listItem = $0.kind { true } else { false } }.count
                    let first = listItemsSeen.insert(containers[item].identity).inserted
                    var text = text
                    let task = first ? Self.task(removedFrom: &text) : nil
                    blocks.append(.listItem(ListItem(marker: first ? (ordered ? "\(ordinal)." : "•") : "", depth: depth,
                                                     task: task, text: text)))
                } else if containers.contains(where: { $0.kind == .blockQuote }) {
                    blocks.append(.quote(text))
                } else {
                    blocks.append(.paragraph(text))
                }
            }
        }

        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if let link = run.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                piece.link = nil
            }
            let intent = run.presentationIntent
            let leaf = intent?.components.first
            if let current = pending, current.leaf?.identity == leaf?.identity, current.intent == intent {
                pending?.text.append(piece)
            } else {
                flush()
                pending = (leaf, intent, piece)
            }
        }
        flush()
        finishTable()
        return blocks
    }

    /// Takes a task's "[ ] " or "[x] " off the start of its item.
    private static func task(removedFrom text: inout AttributedString) -> ListItem.Task? {
        let start = String(text.characters.prefix(4))
        let task: ListItem.Task
        switch start.lowercased() {
        case "[ ] ": task = .open
        case "[x] ": task = .done
        default: return nil
        }
        text.removeSubrange(text.startIndex..<text.characters.index(text.startIndex, offsetBy: 4))
        return task
    }

    private struct TableBuilder {
        let id: Int
        let alignments: [Table.Alignment]
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        var rowIDs: [Int] = []

        mutating func add(_ text: AttributedString, column: Int, row: PresentationIntent.IntentType?) {
            guard let row else { return }
            if case .tableHeaderRow = row.kind {
                Self.set(text, at: column, in: &header)
                return
            }
            if rowIDs.last != row.identity { rowIDs.append(row.identity); rows.append([]) }
            Self.set(text, at: column, in: &rows[rows.count - 1])
        }

        private static func set(_ text: AttributedString, at column: Int, in cells: inout [AttributedString]) {
            while cells.count <= column { cells.append(AttributedString()) }
            cells[column].append(text)
        }

        /// Every row as wide as the widest, so the columns line up.
        var table: Table {
            let width = max(alignments.count, header.count, rows.map(\.count).max() ?? 0)
            func padded(_ cells: [AttributedString]) -> [AttributedString] {
                cells + Array(repeating: AttributedString(), count: width - cells.count)
            }
            return Table(alignments: alignments + Array(repeating: .leading, count: width - alignments.count),
                         header: padded(header), rows: rows.map(padded))
        }
    }
}

private extension MarkdownDocument.Table.Alignment {
    init(_ column: PresentationIntent.TableColumn) {
        switch column.alignment {
        case .center: self = .center
        case .right: self = .trailing
        default: self = .leading
        }
    }
}
