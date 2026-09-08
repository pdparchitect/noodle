import Foundation

/// A plain-text editing operation, not a message mention or delivery primitive.
public struct AgentNameCompletion: Equatable {
    public let range: NSRange
    public let query: String

    public static func request(in text: String, selection: NSRange) -> Self? {
        guard selection.length == 0, let caretRange = Range(selection, in: text) else { return nil }
        let caret = caretRange.lowerBound
        let prefix = text[..<caret]
        guard let at = prefix.lastIndex(of: "@") else { return nil }
        if at != text.startIndex {
            let preceding = text[text.index(before: at)]
            guard preceding.isWhitespace || "([{,:".contains(preceding) else { return nil }
        }
        let query = String(text[text.index(after: at)..<caret])
        guard query.count <= 64, !query.contains(where: { $0.isNewline }),
              query.allSatisfy({ $0.isLetter || $0.isNumber || " '-_.".contains($0) }) else { return nil }
        var end = caret
        while end < text.endIndex {
            let character = text[end]
            guard character.isLetter || character.isNumber || "-_".contains(character) else { break }
            end = text.index(after: end)
        }
        return Self(range: NSRange(at..<end, in: text), query: query)
    }

    public func matches(_ agents: [AgentRecord], preferredIDs: Set<UUID>) -> [AgentRecord] {
        agents.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
            .sorted {
                let left = preferredIDs.contains($0.id), right = preferredIDs.contains($1.id)
                if left != right { return left }
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    public func replacement(name: String, in text: String) -> String {
        guard let replacementRange = Range(range, in: text) else { return name }
        return name + (replacementRange.upperBound == text.endIndex ? " " : "")
    }
}
