import Foundation

extension AppleCommand {
    /// A model often writes the workspace path into a command without quoting it. The path can hold a
    /// space, as in `Application Support`, and Bash then splits it into two words. This escapes each
    /// unquoted copy of those paths so it stays one word. A copy counts only when the path is the whole
    /// word: the command ends there, or a slash or a shell separator follows. Everything else is left as written: quoted
    /// and escaped text, comments, and commands with a here-document.
    static func keepingPathsWhole(_ command: String, paths: [String]) -> String {
        var known: [(path: [Unicode.Scalar], escaped: String)] = []
        for path in Set(paths) {
            if let escaped = escapedForShell(path), escaped != path { known.append((Array(path.unicodeScalars), escaped)) }
        }
        known.sort { $0.path.count > $1.path.count }
        guard !known.isEmpty, !command.contains("<<") else { return command }

        enum Quote { case none, single, double, ansi }
        let input = Array(command.unicodeScalars)
        var output = String.UnicodeScalarView()
        var quote = Quote.none
        var index = 0
        func previousIs(_ allowed: String) -> Bool {
            index == 0 || allowed.unicodeScalars.contains(input[index - 1])
        }
        // A path is the whole word only if the command ends there, or a slash or a separator follows.
        func endsWord(at end: Int) -> Bool {
            end == input.count || "/ \t\n;|&)<>".unicodeScalars.contains(input[end])
        }
        while index < input.count {
            let scalar = input[index]
            switch quote {
            case .single:
                output.append(scalar)
                if scalar == "'" { quote = .none }
                index += 1
            case .double, .ansi:
                if scalar == "\\", index + 1 < input.count {
                    output.append(scalar); output.append(input[index + 1]); index += 2
                    continue
                }
                output.append(scalar)
                if scalar == (quote == .double ? "\"" : "'") { quote = .none }
                index += 1
            case .none:
                if scalar == "\\", index + 1 < input.count {
                    output.append(scalar); output.append(input[index + 1]); index += 2
                    continue
                }
                if scalar == "'" || scalar == "\"" {
                    quote = scalar == "'" ? .single : .double
                } else if scalar == "$", index + 1 < input.count, input[index + 1] == "'" {
                    output.append(scalar); output.append(input[index + 1]); index += 2
                    quote = .ansi
                    continue
                } else if scalar == "#", previousIs(" \t\n;|&()") {
                    // A comment runs to the end of the line.
                    while index < input.count, input[index] != "\n" { output.append(input[index]); index += 1 }
                    continue
                } else if previousIs(" \t\n;|&(<>=:"),
                          let hit = known.first(where: { input[index...].starts(with: $0.path) && endsWord(at: index + $0.path.count) }) {
                    output.append(contentsOf: hit.escaped.unicodeScalars)
                    index += hit.path.count
                    continue
                }
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    private static let plainInPaths = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:,@%=~".unicodeScalars)

    /// The path with a backslash before each character Bash would treat specially. Nil for a path with a
    /// control character, which a backslash cannot protect.
    private static func escapedForShell(_ path: String) -> String? {
        var escaped = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { return nil }
            if !plainInPaths.contains(scalar), scalar.value < 0x80 { escaped.append("\\") }
            escaped.append(scalar)
        }
        return String(escaped)
    }
}
