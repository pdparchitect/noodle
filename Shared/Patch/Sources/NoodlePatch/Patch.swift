import Foundation

/// A patch as `git diff`, `git show` and `git format-patch` write it, read for review: the
/// commits of a series with what each says, and every file's hunks. Lines that belong to no
/// diff are skipped, so a patch pasted into an email or saved from a log still reads.
public struct Patch: Equatable, Sendable {
    public struct Commit: Equatable, Sendable {
        public var sha: String?
        public var subject: String
        /// What the message says beyond its subject.
        public var note: String?
        public var author: String?

        public init(sha: String? = nil, subject: String, note: String? = nil, author: String? = nil) {
            self.sha = sha; self.subject = subject; self.note = note; self.author = author
        }

        public var shortSHA: String? { sha.map { String($0.prefix(7)) } }

        /// The note as paragraphs to show at any width: git wraps a message at 72 columns, so the
        /// lines of a paragraph are joined, while lists, indented lines and empty lines keep their breaks.
        public var flowingNote: String? {
            guard let note else { return nil }
            var lines: [String] = []
            for line in note.components(separatedBy: "\n") {
                if let last = lines.last, !last.isEmpty, !Self.startsBlock(line) {
                    lines[lines.count - 1] = last + " " + line
                } else {
                    lines.append(line)
                }
            }
            return lines.joined(separator: "\n")
        }

        private static func startsBlock(_ line: String) -> Bool {
            guard let first = line.first else { return true }
            if [" ", "\t", "-", "*", "•", ">"].contains(first) { return true }
            let number = line.prefix { $0.isNumber }
            let rest = line.dropFirst(number.count)
            return !number.isEmpty && (rest.hasPrefix(". ") || rest.hasPrefix(") "))
        }
    }

    public struct File: Equatable, Sendable, Identifiable {
        public enum Status: String, Sendable { case added, modified, deleted, renamed, copied }

        /// Nil for a file the patch adds.
        public var oldPath: String?
        /// Nil for a file the patch deletes.
        public var newPath: String?
        public var status: Status
        public var isBinary: Bool
        public var oldMode: String?
        public var newMode: String?
        public var added: Int
        public var removed: Int
        public var hunks: [Hunk]
        /// Its diff is longer than `Patch.maximumFileBytes`: only the counts are kept.
        public var isTooLarge: Bool

        public init(oldPath: String?, newPath: String?, status: Status = .modified, isBinary: Bool = false,
                    oldMode: String? = nil, newMode: String? = nil, added: Int = 0, removed: Int = 0,
                    hunks: [Hunk] = [], isTooLarge: Bool = false) {
            self.oldPath = oldPath; self.newPath = newPath; self.status = status; self.isBinary = isBinary
            self.oldMode = oldMode; self.newMode = newMode; self.added = added; self.removed = removed
            self.hunks = hunks; self.isTooLarge = isTooLarge
        }

        public var path: String { newPath ?? oldPath ?? "" }
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
        /// The folder it is in, or "" at the top of the repository.
        public var folder: String { (path as NSString).deletingLastPathComponent }
        /// "100644 → 100755" when only the mode tells the change apart.
        public var modeChange: String? {
            guard let oldMode, let newMode, oldMode != newMode else { return nil }
            return "\(oldMode) → \(newMode)"
        }
    }

    public struct Hunk: Equatable, Sendable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        /// What follows the second `@@`, usually the function the hunk is in.
        public var section: String
        public var lines: [Line]
        /// The commit it comes from, by its place in `commits`.
        public var commit: Int?

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "",
                    lines: [Line] = [], commit: Int? = nil) {
            self.oldStart = oldStart; self.oldCount = oldCount; self.newStart = newStart; self.newCount = newCount
            self.section = section; self.lines = lines; self.commit = commit
        }

        public var header: String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + (section.isEmpty ? "" : " \(section)")
        }
    }

    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable { case context, added, removed }

        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
        /// The file ends with this line and no newline after it.
        public var noNewlineAtEnd: Bool

        public init(_ kind: Kind, _ text: String, old: Int? = nil, new: Int? = nil, noNewlineAtEnd: Bool = false) {
            self.kind = kind; self.text = text; self.oldNumber = old; self.newNumber = new; self.noNewlineAtEnd = noNewlineAtEnd
        }

        /// The line as the patch writes it, marker first.
        public var patchText: String {
            switch kind {
            case .context: " " + text
            case .added: "+" + text
            case .removed: "-" + text
            }
        }
    }

    /// One per commit of a series, in order; none for a plain diff.
    public var commits: [Commit]
    /// A series' cover letter, `[PATCH 0/N]`, which changes no file.
    public var cover: Commit?
    /// A file changed by several commits of a series is listed once, with the hunks of each.
    public var files: [File]
    /// Files past `maximumFiles`, counted in the totals but not listed.
    public var omittedFiles: Int
    public var added: Int
    public var removed: Int

    public static let maximumFiles = 2_000
    public static let maximumFileBytes = 1 << 20
    /// A larger file is not read as a patch at all, and opens as any other document.
    public static let maximumBytes = 48 << 20

    public init(commits: [Commit] = [], cover: Commit? = nil, files: [File], omittedFiles: Int = 0) {
        self.commits = commits; self.cover = cover; self.files = files; self.omittedFiles = omittedFiles
        added = files.reduce(0) { $0 + $1.added }; removed = files.reduce(0) { $0 + $1.removed }
    }

    /// Patches are told apart by their name, as they arrive with all sorts of media types.
    public static func isPatchFile(name: String, mediaType: String) -> Bool {
        ["patch", "diff"].contains((name as NSString).pathExtension.lowercased()) ||
            ["text/x-patch", "text/x-diff"].contains(mediaType.lowercased())
    }

    /// Nil when `data` holds no diff, is binary, or is larger than `maximumBytes`.
    public init?(data: Data) {
        guard !data.isEmpty, data.count <= Self.maximumBytes, !data.prefix(8_192).contains(0) else { return nil }
        // Split as bytes: as characters, a CRLF ending is one and a combining mark joins the line's marker.
        let lines = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lines: [String] = []
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 10 { end += 1 }
                let next = end + 1
                // Without the carriage return of a patch saved with CRLF endings.
                if end > start, bytes[end - 1] == 13 { end -= 1 }
                lines.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))
                start = next
            }
            return lines
        }
        var parser = PatchParser(lines: lines)
        guard let patch = parser.parse() else { return nil }
        self = patch
    }

    public init?(_ text: String) { self.init(data: Data(text.utf8)) }

    public init?(contentsOf url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    public var fileCount: Int { files.count + omittedFiles }

    /// "24 files, +612 −148"
    public var totals: String {
        "\(fileCount) \(fileCount == 1 ? "file" : "files"), +\(added) −\(removed)"
    }

    /// What a patch is called in a conversation: its commit's subject, a series' cover letter,
    /// or else the name of its file.
    public func title(filename: String) -> String {
        if commits.count == 1 { return commits[0].subject }
        return cover?.subject ?? filename
    }

    /// The single author of every commit, if there is one.
    public var author: String? {
        let authors = Set(commits.compactMap(\.author))
        return authors.count == 1 ? authors.first : nil
    }

    /// "17 files · +558 −126 · 3 commits · by Wren", atop a review.
    public var summary: String {
        var parts = ["\(fileCount) \(fileCount == 1 ? "file" : "files")", "+\(added) −\(removed)"]
        if !commits.isEmpty { parts.append("\(commits.count) \(commits.count == 1 ? "commit" : "commits")") }
        if let author { parts.append("by \(author)") }
        if omittedFiles > 0 { parts.append("\(omittedFiles) not listed") }
        return parts.joined(separator: " · ")
    }

    /// Atop a card: the commit, or the first and last of a series, and whose; a plain diff by the name of its file.
    public func headline(filename: String) -> String {
        let author = author.map { " · \($0)" } ?? ""
        switch commits.count {
        case 0: return filename
        case 1: return (commits[0].shortSHA ?? "") + author
        default: return (commits.first?.shortSHA ?? "") + "…" + (commits.last?.shortSHA ?? "") + author
        }
    }

    /// The files that change most, for a card.
    public func largestFiles(_ count: Int) -> ArraySlice<File> {
        files.sorted { $0.added + $0.removed > $1.added + $1.removed }.prefix(count)
    }
}

// MARK: - Comments

extension Patch {
    /// What a comment on some lines of a file quotes: the file and line numbers, then the lines
    /// as the patch writes them. New numbers where the lines have them; removed lines have only old ones.
    public static func quote(_ lines: [Line], in path: String) -> String {
        let new = lines.compactMap(\.newNumber), old = lines.compactMap(\.oldNumber)
        let numbers = new.isEmpty ? old : new
        var location = path
        if let first = numbers.first, let last = numbers.last {
            location += first == last ? ":\(first)" : ":\(first)-\(last)"
            if new.isEmpty { location += " (removed)" }
        }
        return ([location] + lines.map(\.patchText)).joined(separator: "\n")
    }

    /// Where a comment that quotes lines of this patch goes: under the last line it quotes.
    public func place(of quote: String) -> (path: String, hunk: Int, line: Int)? {
        var lines = quote.components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        let location = lines.removeFirst()
        guard let file = files.first(where: { location == $0.path || location.hasPrefix($0.path + ":") }) else { return nil }
        for (index, hunk) in file.hunks.enumerated() where hunk.lines.count >= lines.count {
            for start in 0...(hunk.lines.count - lines.count) where hunk.lines[start].patchText == lines[0] {
                if lines.indices.allSatisfy({ hunk.lines[start + $0].patchText == lines[$0] }) {
                    return (file.path, index, start + lines.count - 1)
                }
            }
        }
        return nil
    }
}

// MARK: - Reading

/// Reads a patch line by line: a commit's message, then the diff of each file it changes.
private struct PatchParser {
    let lines: [String]
    var index = 0
    var commits: [Patch.Commit] = []
    /// Cover letters, by their place in `commits`.
    var covers: Set<Int> = []
    var entries: [Patch.File] = []
    var file: Patch.File?
    var fileBytes = 0

    init(lines: [String]) { self.lines = lines }

    mutating func parse() -> Patch? {
        while index < lines.count {
            let line = lines[index]
            if let commit = Self.commitStart(line) {
                finishFile()
                index += 1
                readMessage(sha: commit.sha, mailbox: commit.mailbox)
            } else if line.hasPrefix("diff --git ") {
                finishFile()
                index += 1
                readGitHeader(line.dropFirst("diff --git ".count))
            } else if line.hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") {
                // A plain unified diff, without git's header.
                finishFile()
                let old = Self.path(lines[index].dropFirst(4)), new = Self.path(lines[index + 1].dropFirst(4))
                let prefixed = old?.hasPrefix("a/") != false && new?.hasPrefix("b/") != false
                file = Patch.File(oldPath: prefixed ? old.map { String($0.dropFirst(2)) } : old,
                                  newPath: prefixed ? new.map { String($0.dropFirst(2)) } : new,
                                  status: old == nil ? .added : new == nil ? .deleted : .modified)
                index += 2
            } else if line.hasPrefix("@@ "), file != nil {
                readHunk()
            } else {
                index += 1
            }
        }
        finishFile()
        return finish()
    }

    // MARK: Commits

    /// `From <sha> <date>` opens each message of `git format-patch`; `commit <sha>` each commit of `git show` and `git log -p`.
    static func commitStart(_ line: String) -> (sha: String, mailbox: Bool)? {
        let mailbox = line.hasPrefix("From ")
        guard mailbox || line.hasPrefix("commit ") else { return nil }
        let rest = line.dropFirst(mailbox ? 5 : 7)
        let sha = rest.prefix { $0.isHexDigit }
        guard (7...64).contains(sha.count), sha.allSatisfy({ $0.isASCII }) else { return nil }
        let after = rest.dropFirst(sha.count)
        guard mailbox ? after.hasPrefix(" ") : (after.isEmpty || after.hasPrefix(" ")) else { return nil }
        return (String(sha).lowercased(), mailbox)
    }

    mutating func readMessage(sha: String, mailbox: Bool) {
        var subject = "", author: String?, body: [String] = [], isCover = false
        // Headers, up to the first empty line.
        while index < lines.count, !lines[index].isEmpty {
            let line = lines[index]
            if Self.isBoundary(line) { break }
            if mailbox, line.hasPrefix("Subject:") {
                var value = String(line.dropFirst("Subject:".count))
                while index + 1 < lines.count, let next = lines[index + 1].first, next == " " || next == "\t" {
                    index += 1
                    value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                }
                (subject, isCover) = Self.subject(Self.decodeWords(value))
            } else if line.hasPrefix(mailbox ? "From:" : "Author:") {
                author = Self.author(line.dropFirst(mailbox ? 5 : 7))
            }
            index += 1
        }
        // The message, up to format-patch's `---` or the first diff.
        while index < lines.count {
            let line = lines[index]
            if Self.isBoundary(line) || line.hasPrefix("--- ") && index + 1 < lines.count && lines[index + 1].hasPrefix("+++ ") { break }
            if mailbox, line == "---" { index += 1; break }
            if mailbox { body.append(String(line)) }
            else if line.isEmpty || line.hasPrefix("    ") { body.append(String(line.dropFirst(4))) }
            else { break }
            index += 1
        }
        if !mailbox {
            while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
            if !body.isEmpty { subject = body.removeFirst().trimmingCharacters(in: .whitespaces) }
        }
        // A commit made by someone else than who sends it says so first in its body.
        while let first = body.first, first.isEmpty || first.hasPrefix("From: ") || first.hasPrefix("Date: ") { body.removeFirst() }
        let note = body.filter { !$0.hasPrefix("Signed-off-by: ") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isCover { covers.insert(commits.count) }
        commits.append(Patch.Commit(sha: sha, subject: subject.isEmpty ? String(sha.prefix(7)) : subject,
                                    note: note.isEmpty ? nil : note, author: author))
    }

    /// Where a commit, a file or a git signature begins.
    static func isBoundary(_ line: String) -> Bool {
        line.hasPrefix("diff --git ") || commitStart(line) != nil
    }

    /// The subject without `[PATCH 2/3]`, and whether it is a series' cover letter, `[PATCH 0/3]`.
    static func subject(_ value: String) -> (String, Bool) {
        var subject = value.trimmingCharacters(in: .whitespaces)
        var isCover = false
        while subject.hasPrefix("["), let end = subject.firstIndex(of: "]") {
            let tag = subject[subject.index(after: subject.startIndex)..<end]
            if tag.split(separator: " ").last?.hasPrefix("0/") == true { isCover = true }
            subject = subject[subject.index(after: end)...].trimmingCharacters(in: .whitespaces)
        }
        return (subject, isCover)
    }

    /// `Ada Lovelace <ada@example.com>` names Ada Lovelace.
    static func author(_ value: Substring) -> String? {
        var name = decodeWords(String(value)).trimmingCharacters(in: .whitespaces)
        if let open = name.firstIndex(of: "<") { name = name[..<open].trimmingCharacters(in: .whitespaces) }
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count > 1 { name = String(name.dropFirst().dropLast()) }
        return name.isEmpty ? nil : name
    }

    /// Mail headers carry what is not ASCII as encoded words, as in `=?UTF-8?q?Caf=C3=A9?=`.
    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var result = "", rest = Substring(value), afterWord = false
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            guard let word = encodedWord(rest[start.lowerBound...]) else {
                result += before + "=?"
                rest = rest[start.upperBound...]
                afterWord = false
                continue
            }
            // The space between two encoded words is not part of the text.
            if !(afterWord && before.allSatisfy(\.isWhitespace)) { result += before }
            result += word.text
            rest = rest[word.end...]
            afterWord = true
        }
        return result + rest
    }

    private static func encodedWord(_ value: Substring) -> (text: String, end: Substring.Index)? {
        let parts = value.dropFirst(2).split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[3].hasPrefix("=") else { return nil }
        let bytes: [UInt8]
        switch parts[1].lowercased() {
        case "b":
            guard let data = Data(base64Encoded: String(parts[2])) else { return nil }
            bytes = Array(data)
        case "q":
            var decoded: [UInt8] = []
            var characters = Array(parts[2].utf8)[...]
            while let byte = characters.popFirst() {
                if byte == UInt8(ascii: "_") { decoded.append(32) }
                else if byte == UInt8(ascii: "="), characters.count >= 2,
                        let hex = UInt8(String(decoding: characters.prefix(2), as: UTF8.self), radix: 16) {
                    decoded.append(hex)
                    characters.removeFirst(2)
                } else { decoded.append(byte) }
            }
            bytes = decoded
        default: return nil
        }
        let text = parts[0].lowercased() == "iso-8859-1"
            ? String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
            : String(decoding: bytes, as: UTF8.self)
        return (text, parts[3].index(after: parts[3].startIndex))
    }

    // MARK: Files

    mutating func readGitHeader(_ paths: Substring) {
        let (old, new) = Self.gitPaths(paths)
        var file = Patch.File(oldPath: old, newPath: new)
        header: while index < lines.count {
            let line = lines[index]
            func value(_ prefix: String) -> String? {
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            if let mode = value("old mode ") { file.oldMode = mode }
            else if let mode = value("new mode ") { file.newMode = mode }
            else if let mode = value("deleted file mode ") { file.oldMode = mode; file.status = .deleted; file.newPath = nil }
            else if let mode = value("new file mode ") { file.newMode = mode; file.status = .added; file.oldPath = nil }
            else if let path = value("rename from ") { file.oldPath = Self.unquote(Substring(path)); file.status = .renamed }
            else if let path = value("rename to ") { file.newPath = Self.unquote(Substring(path)); file.status = .renamed }
            else if let path = value("copy from ") { file.oldPath = Self.unquote(Substring(path)); file.status = .copied }
            else if let path = value("copy to ") { file.newPath = Self.unquote(Substring(path)); file.status = .copied }
            else if line.hasPrefix("index ") || line.hasPrefix("similarity index ") || line.hasPrefix("dissimilarity index ") {}
            else if line.hasPrefix("Binary files ") { file.isBinary = true; index += 1; break header }
            else if line == "GIT binary patch" {
                file.isBinary = true
                index += 1
                // Base85 lines, `literal` and `delta` blocks and the empty lines between them.
                while index < lines.count, !Self.isBoundary(lines[index]),
                      lines[index].isEmpty || lines[index].first?.isLetter == true { index += 1 }
                break header
            } else if line.hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") {
                let old = Self.path(line.dropFirst(4)), new = Self.path(lines[index + 1].dropFirst(4))
                file.oldPath = old.map(Self.dropPrefix)
                file.newPath = new.map(Self.dropPrefix)
                if old == nil { file.status = .added } else if new == nil { file.status = .deleted }
                index += 2
                break header
            } else { break header }
            index += 1
        }
        self.file = file
    }

    mutating func readHunk() {
        guard let header = Self.hunkHeader(lines[index]) else { index += 1; return }
        index += 1
        var hunk = header
        var old = hunk.oldStart, new = hunk.newStart
        var oldLeft = hunk.oldCount, newLeft = hunk.newCount
        var added = 0, removed = 0, bytes = 0
        while index < lines.count {
            let line = lines[index]
            let marker = line.utf8.first
            if marker == UInt8(ascii: "\\") {
                if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].noNewlineAtEnd = true }
                index += 1
                continue
            }
            // The counts in the header say where the hunk ends, so a signature's `-- ` after it is not a line.
            guard let kind = Self.kind(of: marker, oldLeft: oldLeft, newLeft: newLeft) else { break }
            index += 1
            bytes += line.utf8.count + 1
            let text = marker == nil ? line : String(decoding: line.utf8.dropFirst(), as: UTF8.self)
            switch kind {
            case .context:
                hunk.lines.append(Patch.Line(.context, text, old: old, new: new))
                old += 1; new += 1; oldLeft -= 1; newLeft -= 1
            case .removed:
                hunk.lines.append(Patch.Line(.removed, text, old: old))
                old += 1; oldLeft -= 1; removed += 1
            case .added:
                hunk.lines.append(Patch.Line(.added, text, new: new))
                new += 1; newLeft -= 1; added += 1
            }
        }
        guard var file else { return }
        file.added += added; file.removed += removed
        fileBytes += bytes
        if fileBytes > Patch.maximumFileBytes { file.isTooLarge = true }
        if file.isTooLarge { file.hunks = [] } else {
            hunk.commit = commits.isEmpty ? nil : commits.count - 1
            file.hunks.append(hunk)
        }
        self.file = file
    }

    /// The kind of line `marker` starts while the hunk still expects old and new lines, or nil
    /// where the hunk has ended.
    static func kind(of marker: UInt8?, oldLeft: Int, newLeft: Int) -> Patch.Line.Kind? {
        switch marker {
        // Some mail programs drop the space that starts an empty line of context.
        case UInt8(ascii: " "), nil: oldLeft > 0 && newLeft > 0 ? .context : nil
        case UInt8(ascii: "-"): oldLeft > 0 ? .removed : nil
        case UInt8(ascii: "+"): newLeft > 0 ? .added : nil
        default: nil
        }
    }

    /// `@@ -12,7 +12,9 @@ func capture()`; a count left out is 1.
    static func hunkHeader(_ line: String) -> Patch.Hunk? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = range(parts[1].dropFirst()), let new = range(parts[2].dropFirst()) else { return nil }
        var section = ""
        if parts.count == 4 {
            let rest = parts[3]
            guard rest.hasPrefix("@@") else { return nil }
            section = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        return Patch.Hunk(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count, section: section)
    }

    static func range(_ value: Substring) -> (start: Int, count: Int)? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]), start >= 0, parts.count <= 2 else { return nil }
        guard parts.count == 2 else { return (start, 1) }
        guard let count = Int(parts[1]), count >= 0 else { return nil }
        return (start, count)
    }

    mutating func finishFile() {
        guard let file else { return }
        entries.append(file)
        self.file = nil
        fileBytes = 0
    }

    func finish() -> Patch? {
        // A file changed by several commits is reviewed once.
        var files: [Patch.File] = []
        var positions: [String: Int] = [:]
        for entry in entries {
            guard let position = positions[entry.path] else {
                positions[entry.path] = files.count
                files.append(entry)
                continue
            }
            var file = files[position]
            file.added += entry.added; file.removed += entry.removed
            file.isBinary = file.isBinary || entry.isBinary
            file.isTooLarge = file.isTooLarge || entry.isTooLarge
            file.hunks = file.isTooLarge ? [] : file.hunks + entry.hunks
            file.newPath = entry.newPath
            file.newMode = entry.newMode ?? file.newMode
            if entry.status == .deleted { file.status = .deleted }
            files[position] = file
        }
        guard !files.isEmpty else { return nil }
        let listed = Array(files.prefix(Patch.maximumFiles))
        var patch = Patch(commits: commits.enumerated().filter { !covers.contains($0.offset) }.map(\.element),
                          cover: covers.min().map { commits[$0] }, files: listed, omittedFiles: files.count - listed.count)
        patch.added = files.reduce(0) { $0 + $1.added }
        patch.removed = files.reduce(0) { $0 + $1.removed }
        // Hunks name their commit by its place among the commits that are kept.
        if !covers.isEmpty {
            let kept = (0..<commits.count).filter { !covers.contains($0) }
            let place = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
            for file in patch.files.indices {
                for hunk in patch.files[file].hunks.indices {
                    patch.files[file].hunks[hunk].commit = patch.files[file].hunks[hunk].commit.flatMap { place[$0] }
                }
            }
        }
        return patch
    }

    // MARK: Paths

    /// The two paths of `diff --git a/old b/new`, which a rename header or `---`/`+++` replaces.
    static func gitPaths(_ value: Substring) -> (String?, String?) {
        if value.hasPrefix("\"") || value.hasSuffix("\"") {
            var tokens: [String] = []
            var rest = value
            while !rest.isEmpty {
                rest = rest.drop { $0 == " " }
                if rest.hasPrefix("\"") {
                    var end = rest.index(after: rest.startIndex)
                    while end < rest.endIndex, rest[end] != "\"" {
                        if rest[end] == "\\" { end = rest.index(after: end) }
                        if end < rest.endIndex { end = rest.index(after: end) }
                    }
                    let token = rest[rest.startIndex..<min(rest.index(after: end), rest.endIndex)]
                    tokens.append(unquote(token))
                    rest = rest[min(rest.index(after: end), rest.endIndex)...]
                } else {
                    let token = rest.prefix { $0 != " " }
                    tokens.append(String(token))
                    rest = rest.dropFirst(token.count)
                }
            }
            guard tokens.count == 2 else { return (nil, nil) }
            return (dropPrefix(tokens[0]), dropPrefix(tokens[1]))
        }
        // Without quotes, a path with spaces is found where both halves name the same file.
        let text = String(value)
        if text.count % 2 == 1 {
            let half = text.count / 2
            let old = String(text.prefix(half)), new = String(text.suffix(half))
            if old.dropFirst(2) == new.dropFirst(2) { return (dropPrefix(old), dropPrefix(new)) }
        }
        if let split = text.range(of: " b/") {
            return (dropPrefix(String(text[..<split.lowerBound])), String(text[split.upperBound...]))
        }
        return (nil, nil)
    }

    static func dropPrefix(_ path: String) -> String {
        path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    /// The path of a `---` or `+++` line, nil for /dev/null. A date after a tab is dropped.
    static func path(_ value: Substring) -> String? {
        let path = value.hasPrefix("\"") ? unquote(value.prefix { $0 != "\t" }) : String(value.prefix { $0 != "\t" })
        return path == "/dev/null" ? nil : path
    }

    /// Git quotes a path with unusual characters as a C string, with UTF-8 bytes in octal.
    static func unquote(_ value: Substring) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return String(value) }
        var bytes: [UInt8] = []
        var characters = Array(value.dropFirst().dropLast().utf8)[...]
        while let byte = characters.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = characters.popFirst() else { bytes.append(byte); continue }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octal = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = characters.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    octal = octal * 8 + Int(digit - UInt8(ascii: "0"))
                    characters.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: octal))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
