import Foundation

public enum MarkdownPlainText {
    public static func convert(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let visibleText = markdown
            .split(whereSeparator: \Character.isNewline)
            .compactMap { line -> String? in
                let source = String(line)
                let trimmed = source.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("```"), !trimmed.hasPrefix("~~~") else { return nil }
                guard let attributed = try? AttributedString(markdown: source, options: options) else {
                    return source
                }
                return String(attributed.characters)
            }
            .joined(separator: " ")
        return visibleText
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}
