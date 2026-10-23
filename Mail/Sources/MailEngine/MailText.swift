import CoreFoundation
import Foundation

enum MailText {
    /// Text from bytes, trying in order: the declared charset, UTF-8, Windows-1250, then ISO-8859-2 (the last two are what older Czech mail uses).
    /// ISO-8859-2 accepts every byte, so the chain always ends in text.
    static func decode(_ data: Data, charset: String?) -> String {
        var candidates: [String.Encoding] = []
        if let charset, let declared = encoding(named: charset) { candidates.append(declared) }
        candidates += [.utf8, .windowsCP1250, .isoLatin2]
        for encoding in candidates {
            // An "us-ascii" label on 8-bit mail is usually wrong, so the label is skipped instead of trusted,
            // whatever the platform's ASCII decoder does.
            if encoding == .ascii, data.contains(where: { $0 >= 0x80 }) { continue }
            if let text = String(data: data, encoding: encoding) { return text }
        }
        // Not reached, because ISO-8859-2 accepts every byte; String(data:encoding:) is optional, so an answer is still needed.
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name.trimmingCharacters(in: .whitespaces) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Readable plain text from an HTML body. Drops head, style and script, keeps line structure, and decodes entities.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        text = removingBlocks(from: text)
        // Line breaks in HTML source are just spaces; only tags make lines.
        text = replace(#"\s+"#, in: text, with: " ")
        text = replace(#"(?i)<br\s*/?>"#, in: text, with: "\n")
        text = replace(#"(?i)<li\b[^<>]*>"#, in: text, with: "\n- ")
        text = replace(#"(?i)</(p|div|tr|h[1-6]|ul|ol|table)\s*>"#, in: text, with: "\n")
        text = replace(#"(?i)</t[dh]\s*>"#, in: text, with: " ")
        text = replace(#"<[^<>]+>"#, in: text, with: "")
        text = decodeEntities(text)
        // Empty cells and entities leave runs of spaces and tabs inside a line.
        text = replace(#"[ \t]{2,}"#, in: text, with: " ")
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        text = lines.joined(separator: "\n")
        text = replace(#"\n{3,}"#, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A header value on one line: CR and LF become spaces and the ends are trimmed.
    static func singleLine(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return replace(#" {2,}"#, in: flattened, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The longest header value (subject, sender) a bot receives, in characters.
    static let headerLimit = 300
    /// The most addresses a bot receives from one recipient header.
    static let recipientLimit = 20
    /// The most attachments a bot receives from one message; `read` counts the rest.
    static let attachmentLimit = 50
    /// The longest line a mail header may have (RFC 5322), in octets.
    static let lineLimit = 998

    /// A header value cut to `limit` characters, the last one "…", so a spam subject of 50,000 characters cannot flood a bot.
    /// It cuts between Characters, so an emoji or a letter with its accent is never split. A single Character can still be huge
    /// (a letter with 50,000 combining marks), so the result is also held to four Unicode scalars per allowed character, and that
    /// last cut may fall inside such a Character.
    static func capped(_ value: String?, limit: Int = MailText.headerLimit) -> String? {
        guard var result = value else { return nil }
        if result.count > limit { result = String(result.prefix(limit - 1)) + "\u{2026}" }
        let scalarLimit = limit * 4
        if result.unicodeScalars.count > scalarLimit {
            result = String(String.UnicodeScalarView(result.unicodeScalars.prefix(scalarLimit - 1))) + "\u{2026}"
        }
        return result
    }

    /// The first `count` addresses, then one entry "… and N more" for the rest, so 2,000 recipients cannot flood a bot.
    /// Each kept entry is cut like a header value, because a display name is as free to be huge as a subject.
    static func capped(_ values: [String], count: Int = MailText.recipientLimit) -> [String] {
        let kept = values.prefix(count).map { capped($0) ?? $0 }
        guard values.count > count else { return kept }
        return kept + ["\u{2026} and \(values.count - count) more"]
    }

    /// A Message-ID as the server gave it, or nil when it is longer than a header line may be. It is never cut: a cut ID
    /// names no message, and a reply that threads on it would thread on nothing.
    static func messageID(_ value: String?) -> String? {
        guard let value, value.utf8.count <= lineLimit else { return nil }
        return value
    }

    /// The text with every line break written as CRLF, whether it came as CRLF, LF or a lone CR. It works on Unicode scalars,
    /// because Swift reads "\r\n" as one Character.
    static func crlfLineBreaks(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", afterCR {
                afterCR = false
                continue
            }
            afterCR = scalar == "\r"
            if scalar == "\r" || scalar == "\n" { result.append(contentsOf: "\r\n".unicodeScalars) } else { result.append(scalar) }
        }
        return String(result)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Drops the head, style and script elements with their content in one forward pass, so a crafted mail cannot make it slow.
    /// A style or script that never closes runs to the end of the text, as in a browser. A head ends at its closing tag or at the
    /// body tag, whichever comes first. With neither, the head is no element: its tag stays, and the tag stripper removes just that.
    private static func removingBlocks(from text: String) -> String {
        let search = ForwardSearch(text)
        var kept = ""
        var position = text.startIndex
        while let (name, opening) = ["head", "style", "script"]
            .compactMap({ name in search.next("<" + name, from: position).map { (name, $0) } })
            .min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
            kept += text[position..<opening.lowerBound]
            if let end = blockEnd(of: name, opening: opening, in: text, search: search) {
                position = end
            } else {
                kept += text[opening]
                position = opening.upperBound
            }
        }
        return kept + text[position...]
    }

    /// Where the element with this opening tag ends, or nil for a head that has neither a closing tag nor a body tag.
    private static func blockEnd(of name: String, opening: Range<String.Index>, in text: String, search: ForwardSearch) -> String.Index? {
        let closing = search.next("</" + name, from: opening.lowerBound)
        guard name == "head" else { return closing.map { endOfTag(closing: $0, in: text) } ?? text.endIndex }
        let body = search.next("<body", from: opening.lowerBound)
        if let closing, body.map({ closing.lowerBound < $0.lowerBound }) ?? true { return endOfTag(closing: closing, in: text) }
        return body?.lowerBound
    }

    /// Just past the `>` that ends the closing tag found at `closing`, or the end of the text when there is none.
    private static func endOfTag(closing: Range<String.Index>, in text: String) -> String.Index {
        guard let bracket = text[closing.upperBound...].firstIndex(of: ">") else { return text.endIndex }
        return text.index(after: bracket)
    }

    /// Finds tags going forward only and remembers where each was last found, so asking again never scans the same text twice.
    private final class ForwardSearch {
        private let text: String
        private var known: [String: (from: String.Index, found: Range<String.Index>?)] = [:]

        init(_ text: String) { self.text = text }

        /// The first `tag` at or after `position` that is a whole tag name. Positions asked about for one tag only move forward.
        func next(_ tag: String, from position: String.Index) -> Range<String.Index>? {
            if let (from, cached) = known[tag], from <= position {
                guard let found = cached else { return nil }
                if found.lowerBound >= position { return found }
            }
            let found = MailText.find(tag, in: text, from: position)
            known[tag] = (position, found)
            return found
        }
    }

    /// The first `tag` from `start` on that is a whole tag name, not the start of a longer one: "<header" is not "<head".
    private static func find(_ tag: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        var from = start
        while let found = text.range(of: tag, options: .caseInsensitive, range: from..<text.endIndex) {
            guard let next = text[found.upperBound...].first, next.isLetter else { return found }
            from = found.upperBound
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        let named = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&ndash;": "\u{2013}", "&mdash;": "\u{2014}", "&hellip;": "\u{2026}", "&bdquo;": "\u{201E}", "&ldquo;": "\u{201C}",
            "&rdquo;": "\u{201D}", "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&laquo;": "\u{AB}", "&raquo;": "\u{BB}",
            "&euro;": "\u{20AC}", "&copy;": "\u{A9}", "&eacute;": "\u{E9}", "&aacute;": "\u{E1}", "&iacute;": "\u{ED}",
            "&oacute;": "\u{F3}", "&uacute;": "\u{FA}", "&yacute;": "\u{FD}",
        ]
        var result = text
        for (entity, value) in named where entity != "&amp;" { result = result.replacingOccurrences(of: entity, with: value) }
        // One forward pass: the pieces between entities and the decoded characters are appended in order,
        // so a long text is not rewritten once per entity.
        let numeric = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        var decoded = ""
        var copied = result.startIndex
        for match in numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            guard let whole = Range(match.range, in: result), let body = Range(match.range(at: 1), in: result) else { continue }
            let token = result[body]
            let scalarValue = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { continue }
            decoded += result[copied..<whole.lowerBound]
            decoded.unicodeScalars.append(scalar)
            copied = whole.upperBound
        }
        result = decoded + result[copied...]
        // &amp; last, so "&amp;lt;" stays "&lt;" instead of becoming "<".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
