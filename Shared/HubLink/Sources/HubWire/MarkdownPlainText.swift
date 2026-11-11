import Foundation

public enum MarkdownPlainText {
    public static func convert(_ markdown: String) -> String {
        let visibleText = markdown
            .split(whereSeparator: \Character.isNewline)
            .compactMap { line -> String? in
                let source = String(line)
                let trimmed = source.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("```"), !trimmed.hasPrefix("~~~") else { return nil }
                return InlineMarkdown.plainText(source, blocks: true)
            }
            .joined(separator: " ")
        return visibleText
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

/// One line of markdown as the text it shows. Foundation's parser does it on Apple platforms;
/// elsewhere Foundation has none, so `stripped` takes off the common markup.
public enum InlineMarkdown {
    /// `blocks` also takes off a heading, list or quote marker at the start of the line.
    package static func plainText(_ line: String, blocks: Bool = false) -> String {
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: blocks ? .full : .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: line, options: options) else { return line }
        return String(parsed.characters)
        #else
        return stripped(line, blocks: blocks)
        #endif
    }

    package static func stripped(_ line: String, blocks: Bool = false) -> String {
        var text = Substring(line)
        if blocks {
            text = text.drop { $0 == " " }
            for marker in [#"^#{1,6}(\s+|$)"#, #"^>\s?"#, #"^[-*+]\s+"#, #"^\d{1,9}[.)]\s+"#] {
                if let range = text.range(of: marker, options: .regularExpression) { text = text[range.upperBound...] }
            }
            if text.allSatisfy({ "-*_ ".contains($0) }), text.filter({ $0 != " " }).count >= 3 { return "⸻" }
            text = Substring(text.trimmingCharacters(in: .whitespaces))
        }
        return runs(Array(text), style: Run("")).map(\.text).joined()
    }

    /// A piece of a line and how it is styled, as Foundation's parser reads inline markdown.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var strong: Bool
        public var emphasis: Bool
        public var strikethrough: Bool
        public var code: Bool
        /// Where the piece links to, as written.
        public var link: String?

        public init(_ text: String, strong: Bool = false, emphasis: Bool = false, strikethrough: Bool = false,
                    code: Bool = false, link: String? = nil) {
            self.text = text
            self.strong = strong
            self.emphasis = emphasis
            self.strikethrough = strikethrough
            self.code = code
            self.link = link
        }

        func styled(like other: Run) -> Bool {
            strong == other.strong && emphasis == other.emphasis && strikethrough == other.strikethrough
                && code == other.code && link == other.link
        }
    }

    /// A line's inline markdown as the pieces it shows, each with its style, for screens that draw them
    /// where Foundation cannot read markdown.
    public static func runs(_ line: String) -> [Run] {
        // Neighbours styled alike are one piece, as Foundation gives them.
        runs(Array(line), style: Run("")).reduce(into: [Run]()) { merged, run in
            if let last = merged.last, last.styled(like: run) { merged[merged.count - 1].text += run.text } else { merged.append(run) }
        }
    }

    private static func runs(_ chars: [Character], style: Run) -> [Run] {
        var out: [Run] = []
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            var run = style
            run.text = text
            out.append(run)
            text = ""
        }
        func append(_ runs: [Run]) {
            flush()
            out += runs
        }
        var i = 0
        func run(of mark: Character, at index: Int) -> Int {
            var end = index
            while end < chars.count, chars[end] == mark { end += 1 }
            return end - index
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                text.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                let count = run(of: "`", at: i)
                var j = i + count
                while j < chars.count {
                    if chars[j] == "`" {
                        let closing = run(of: "`", at: j)
                        if closing == count {
                            var code = String(chars[(i + count)..<j])
                            if code.count > 1, code.first == " ", code.last == " ", !code.allSatisfy({ $0 == " " }) {
                                code = String(code.dropFirst().dropLast())
                            }
                            var piece = style
                            piece.text = code
                            piece.code = true
                            append([piece]); i = j + closing; break
                        }
                        j += closing
                    } else { j += 1 }
                }
                if j >= chars.count { text += String(repeating: "`", count: count); i += count }
                continue
            }
            if c == "[" || (c == "!" && i + 1 < chars.count && chars[i + 1] == "["), let link = link(chars, at: c == "!" ? i + 1 : i) {
                var linked = style
                linked.link = link.destination
                append(runs(Array(chars[link.text]), style: linked)); i = link.end; continue
            }
            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">"), close > i + 1 {
                let inner = String(chars[(i + 1)..<close])
                if !inner.contains(" "), inner.range(of: #"^([a-zA-Z][a-zA-Z0-9+.-]{1,31}:\S*|[^@\s]+@[^@\s]+)$"#, options: .regularExpression) != nil {
                    var piece = style
                    piece.text = inner
                    piece.link = inner.contains(":") ? inner : "mailto:" + inner
                    append([piece]); i = close + 1; continue
                }
            }
            if c == "*" || c == "_" || c == "~" {
                let count = run(of: c, at: i)
                if let close = closingRun(chars, mark: c, count: count, from: i) {
                    var inner = style
                    if c == "~" {
                        inner.strikethrough = true
                    } else {
                        if count != 2 { inner.emphasis = true }
                        if count >= 2 { inner.strong = true }
                    }
                    append(runs(Array(chars[(i + count)..<close]), style: inner)); i = close + count; continue
                }
                text += String(repeating: c, count: count); i += count; continue
            }
            text.append(c); i += 1
        }
        flush()
        return out
    }

    /// `[text](destination)` from the bracket at `start`: the text's range, where the link goes, and where
    /// it ends.
    private static func link(_ chars: [Character], at start: Int) -> (text: Range<Int>, destination: String, end: Int)? {
        var depth = 0, j = start
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 } else if chars[j] == "]" { depth -= 1; if depth == 0 { break } }
            j += 1
        }
        guard j < chars.count, j + 1 < chars.count, chars[j + 1] == "(" else { return nil }
        var parens = 0, k = j + 1
        var angled = false
        while k < chars.count {
            if chars[k] == "<", k == j + 2 { angled = true }
            if angled { if chars[k] == ">" { angled = false } } else if chars[k] == "(" { parens += 1 } else if chars[k] == ")" {
                parens -= 1; if parens == 0 { break }
            }
            k += 1
        }
        guard k < chars.count else { return nil }
        var destination = String(chars[(j + 2)..<k]).trimmingCharacters(in: .whitespaces)
        if destination.hasPrefix("<"), let close = destination.firstIndex(of: ">") {
            destination = String(destination[destination.index(after: destination.startIndex)..<close])
        } else if let title = destination.firstIndex(of: " ") {
            // A title after the destination is not part of it.
            destination = String(destination[..<title])
        }
        return (start + 1..<j, destination, k + 1)
    }

    /// Where emphasis opened by `count` of `mark` at `open` closes. It opens only before text, and
    /// underscores only at the start of a word, as CommonMark has it.
    private static func closingRun(_ chars: [Character], mark: Character, count: Int, from open: Int) -> Int? {
        if mark == "~", count != 2 && count != 1 { return nil }
        guard count <= 3, open + count < chars.count, !chars[open + count].isWhitespace else { return nil }
        if mark == "_", open > 0, chars[open - 1].isLetter || chars[open - 1].isNumber { return nil }
        var j = open + count
        // Runs of the same mark opened inside, which a closing run closes first, as in `*a **b***`.
        var inner: [Int] = []
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "`" {
                // Code spans bind tighter than emphasis.
                var k = j + 1
                while k < chars.count, chars[k] != "`" { k += 1 }
                j = k + 1; continue
            }
            if chars[j] == mark {
                var end = j
                while end < chars.count, chars[end] == mark { end += 1 }
                let after = end < chars.count ? chars[end] : " "
                var available = end - j
                if !chars[j - 1].isWhitespace, j > open + count {
                    while available > 0, let open = inner.last {
                        let used = min(open, available)
                        available -= used
                        if used == open { inner.removeLast() } else { inner[inner.count - 1] -= used }
                    }
                    if available >= count, mark != "_" || !(after.isLetter || after.isNumber) { return end - available }
                }
                if available > 0, !after.isWhitespace, end < chars.count { inner.append(available) }
                j = end; continue
            }
            j += 1
        }
        return nil
    }
}
