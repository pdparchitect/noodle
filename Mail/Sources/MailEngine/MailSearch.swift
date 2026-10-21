import Foundation

/// One IMAP search criterion; a list of them must all match.
enum SearchTerm: Equatable, Sendable {
    case all
    case unseen
    case from(String)
    case to(String)
    case subject(String)
    case text(String)
    case since(Date)
    case before(Date)
}

enum MailSearch {
    /// The terms for a query. Blank strings are skipped; nothing to filter means everything.
    static func terms(for query: MessageQuery) -> [SearchTerm] {
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        var terms: [SearchTerm] = []
        if query.unreadOnly { terms.append(.unseen) }
        if let from = clean(query.from) { terms.append(.from(from)) }
        if let to = clean(query.to) { terms.append(.to(to)) }
        if let subject = clean(query.subject) { terms.append(.subject(subject)) }
        if let text = clean(query.text) { terms.append(.text(text)) }
        if let since = query.since { terms.append(.since(since)) }
        if let before = query.before { terms.append(.before(before)) }
        return terms.isEmpty ? [.all] : terms
    }

    /// The newest `limit` UIDs, newest first, only below `beforeUID` when given.
    static func page(_ uids: [Int], beforeUID: Int?, limit: Int) -> [Int] {
        let older = Set(uids).filter { beforeUID == nil || $0 < beforeUID! }
        return Array(older.sorted(by: >).prefix(max(limit, 0)))
    }
}
