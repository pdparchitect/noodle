import Foundation

public enum MessageLink {
    #if canImport(Darwin)
    public static func firstPublicWebURL(in markdown: String) -> URL? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            for run in attributed.runs {
                if let link = run.link, let safeURL = publicWebURL(from: link) {
                    return safeURL
                }
            }
        }

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }

        // Never in code: a name there that ends like a web address, such as session.id or report.md, is not a link.
        let prose = withoutCode(markdown)
        let range = NSRange(prose.startIndex..., in: prose)
        var result: URL?
        detector.enumerateMatches(in: prose, range: range) { match, _, stop in
            guard let candidate = match?.url,
                  let safeURL = publicWebURL(from: candidate) else { return }
            result = safeURL
            stop.pointee = true
        }
        return result
    }

    /// The text with its fenced code blocks and inline code spans taken out, each left as a line break or a space so
    /// the words around them stay apart.
    static func withoutCode(_ markdown: String) -> String {
        var lines: [Substring] = [], inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); lines.append(""); continue }
            lines.append(inFence ? "" : line)
        }
        var result = "", inSpan = false
        for character in lines.joined(separator: "\n") {
            if character == "`" { inSpan.toggle(); result.append(" "); continue }
            // An unclosed backtick never runs past its line.
            if character == "\n" { inSpan = false }
            if !inSpan { result.append(character) }
        }
        return result
    }
    #endif

    public static func publicWebURL(from url: URL, preservingFragment: Bool = false) -> URL? {
        guard let canonical = webURL(from: url, preservingFragment: preservingFragment),
              let host = canonical.host, isPublicHost(host) else { return nil }
        return canonical
    }

    /// An http(s) page in canonical form, which may be on this Mac or the local network.
    public static func webURL(from url: URL, preservingFragment: Bool = false) -> URL? {
        guard url.absoluteString.count <= 2_048,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else { return nil }

        var canonical = components
        canonical.scheme = scheme
        canonical.host = rawHost
        if !preservingFragment { canonical.fragment = nil }
        return canonical.url
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard normalized != "localhost",
              !normalized.hasSuffix(".localhost"),
              !normalized.hasSuffix(".local"),
              !normalized.contains(":") else { return false }

        let octets = normalized.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return true }

        let a = octets[0]
        let b = octets[1]
        switch (a, b) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 0), (192, 168):
            return false
        case (100, 64...127), (172, 16...31), (198, 18...19):
            return false
        case (224...255, _):
            return false
        default:
            return true
        }
    }
}
