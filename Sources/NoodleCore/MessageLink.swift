import Foundation

public enum MessageLink {
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

        let range = NSRange(markdown.startIndex..., in: markdown)
        var result: URL?
        detector.enumerateMatches(in: markdown, range: range) { match, _, stop in
            guard let candidate = match?.url,
                  let safeURL = publicWebURL(from: candidate) else { return }
            result = safeURL
            stop.pointee = true
        }
        return result
    }

    public static func publicWebURL(from url: URL, preservingFragment: Bool = false) -> URL? {
        guard url.absoluteString.count <= 2_048,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty,
              isPublicHost(rawHost) else { return nil }

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
