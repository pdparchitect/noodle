import Foundation

/// Shared validation for bot/group names, never for message bodies or backstories.
public enum ConversationName {
    public static let maximumLength = 100

    public enum ValidationError: LocalizedError, Equatable {
        case empty, multipleLines, tooLong
        public var errorDescription: String? {
            switch self {
            case .empty: return "Enter a name."
            case .multipleLines: return "Names must be a single line. Put longer text in Description or Backstory."
            case .tooLong: return "Keep names to 100 characters or fewer."
            }
        }
    }

    public static func validated(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.empty }
        guard name.rangeOfCharacter(from: .newlines.union(.controlCharacters)) == nil else {
            throw ValidationError.multipleLines
        }
        guard name.count <= maximumLength else { throw ValidationError.tooLong }
        return name
    }

    public static func error(for raw: String) -> String? {
        do { _ = try validated(raw); return nil }
        catch { return error.localizedDescription }
    }

    /// Bound legacy names for display without rewriting saved user data.
    public static func display(_ raw: String) -> String {
        let firstLine = raw.components(separatedBy: .newlines.union(.controlCharacters))
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? "Untitled"
        return firstLine.count > maximumLength ? String(firstLine.prefix(maximumLength - 1)) + "…" : firstLine
    }
}
