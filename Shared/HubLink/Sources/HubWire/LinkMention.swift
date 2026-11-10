import Foundation

/// Whether a message names its reader, which notifies them in a group set to Mentions only. A mention is the
/// person's name, not an @handle: their full name, or else their first name alone, as whole words, whatever the
/// case or accents. Names inside code don't count. The Hub, the Mac and the iPhone all ask here, so they agree.
public enum LinkMention {
    public static func mentions(_ text: String, name: String) -> Bool {
        let full = words(fold(name))
        guard let first = full.first else { return false }
        let prose = words(fold(withoutCode(text)))
        return contains(prose, full) || (full.count > 1 && contains(prose, [first]))
    }

    /// Whether `words` has `name`'s words in a row.
    private static func contains(_ words: [Substring], _ name: [Substring]) -> Bool {
        guard words.count >= name.count else { return false }
        return (0...(words.count - name.count)).contains { start in
            name.indices.allSatisfy { words[start + $0] == name[$0] }
        }
    }

    /// Letters and digits in runs: anything else, spaces and punctuation alike, ends a word.
    private static func words(_ text: String) -> [Substring] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Fenced blocks, closed or running to the end, and inline code spans.
    private static let code = try! NSRegularExpression(pattern: "(```|~~~)[\\s\\S]*?(\\1|\\z)|`[^`\\n]*`")

    private static func withoutCode(_ text: String) -> String {
        code.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
}
