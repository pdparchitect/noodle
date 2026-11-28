/// A key or other input, decoded from what the terminal sends.
public enum Key: Equatable, Sendable {
    case text(String)
    case paste(String)
    case enter, tab, backTab, backspace, delete, escape
    case up, down, left, right, home, end, pageUp, pageDown
    case control(Character)
    case wheelUp, wheelDown
}

/// Turns bytes into keys. A sequence or character cut off at the end of one read is kept for the next; an Escape
/// on its own at the end of a read waits too, as it may start a sequence, until `flush` says no more is coming.
public struct KeyDecoder: Sendable {
    private var pending: [UInt8] = []
    private var pasting: [UInt8]?
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    public init() {}

    /// Whether bytes are held that a moment's quiet would settle: a lone Escape or a cut-off sequence.
    public var isWaiting: Bool { pasting == nil && !pending.isEmpty }

    public mutating func decode(_ bytes: [UInt8]) -> [Key] {
        pending += bytes
        var keys: [Key] = []
        var text: [UInt8] = []
        func flushText() {
            if !text.isEmpty { keys.append(.text(String(decoding: text, as: UTF8.self))); text = [] }
        }
        var index = 0
        while index < pending.count {
            if var paste = pasting {
                // Pasted text runs until the end marker, whatever it holds.
                if let end = find(Self.pasteEnd, from: index) {
                    paste += pending[index..<end]
                    keys.append(.paste(String(decoding: paste, as: UTF8.self)))
                    pasting = nil
                    index = end + Self.pasteEnd.count
                    continue
                }
                // Keep what might be the start of the end marker for the next read.
                let keep = Self.partialSuffix(of: pending[index...], matching: Self.pasteEnd)
                paste += pending[index..<(pending.count - keep)]
                pasting = paste
                pending = Array(pending.suffix(keep))
                return keys
            }
            let byte = pending[index]
            switch byte {
            case 0x1B:
                flushText()
                guard index + 1 < pending.count else {
                    pending.removeFirst(index)
                    return keys
                }
                switch escapeSequence(at: index) {
                case .key(let key, let length):
                    if let key { keys.append(key) }
                    index += length
                case .incomplete:
                    pending.removeFirst(index)
                    return keys
                case .notASequence:
                    keys.append(.escape)
                    index += 1
                }
            case 0x0D: flushText(); keys.append(.enter); index += 1
            case 0x09: flushText(); keys.append(.tab); index += 1
            case 0x7F, 0x08: flushText(); keys.append(.backspace); index += 1
            case 0x00: flushText(); index += 1
            case 0x01...0x1A, 0x1C...0x1F:
                flushText()
                // Control-J sends a line feed, which is how a new line is typed in the message field.
                keys.append(.control(Character(UnicodeScalar(byte < 0x1B ? byte + 0x60 : byte + 0x40))))
                index += 1
            default:
                text.append(byte); index += 1
            }
        }
        // A character whose bytes have not all come yet waits for the rest.
        let cut = Self.incompleteUTF8Suffix(text)
        pending = Array(text.suffix(cut))
        text.removeLast(cut)
        flushText()
        return keys
    }

    /// Whatever is still held, after a moment with nothing more: a lone Escape is the Escape key.
    public mutating func flush() -> [Key] {
        guard isWaiting else { return [] }
        let held = pending
        pending = []
        guard held.first == 0x1B else { return [.text(String(decoding: held, as: UTF8.self))] }
        return [.escape] + decode(Array(held.dropFirst()))
    }

    private func find(_ needle: [UInt8], from start: Int) -> Int? {
        guard pending.count >= needle.count, start <= pending.count - needle.count else { return nil }
        for i in start...(pending.count - needle.count) where pending[i..<(i + needle.count)].elementsEqual(needle) { return i }
        return nil
    }

    /// How many bytes at the end of `bytes` could begin `marker`.
    static func partialSuffix(of bytes: ArraySlice<UInt8>, matching marker: [UInt8]) -> Int {
        for length in stride(from: min(marker.count - 1, bytes.count), to: 0, by: -1)
        where bytes.suffix(length).elementsEqual(marker.prefix(length)) {
            return length
        }
        return 0
    }

    /// How many bytes at the end of `bytes` start a UTF-8 character that needs more.
    static func incompleteUTF8Suffix(_ bytes: [UInt8]) -> Int {
        for back in 1...min(3, max(1, bytes.count)) where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return needed > back ? back : 0
        }
        return 0
    }

    private enum Sequence {
        /// The key it stands for, nil for one that means nothing here, and how many bytes it takes.
        case key(Key?, Int)
        case incomplete
        case notASequence
    }

    private mutating func escapeSequence(at index: Int) -> Sequence {
        let rest = pending[(index + 1)...]
        let first = rest[rest.startIndex]
        if first == UInt8(ascii: "O") {
            guard rest.count >= 2 else { return .incomplete }
            switch rest[rest.startIndex + 1] {
            case UInt8(ascii: "A"): return .key(.up, 3)
            case UInt8(ascii: "B"): return .key(.down, 3)
            case UInt8(ascii: "C"): return .key(.right, 3)
            case UInt8(ascii: "D"): return .key(.left, 3)
            case UInt8(ascii: "H"): return .key(.home, 3)
            case UInt8(ascii: "F"): return .key(.end, 3)
            default: return .key(nil, 3)
            }
        }
        guard first == UInt8(ascii: "[") else { return .notASequence }
        // CSI: parameter and intermediate bytes, then a final byte in @...~.
        var end = rest.startIndex + 1
        while end < rest.endIndex, (0x20...0x3F).contains(rest[end]) { end += 1 }
        guard end < rest.endIndex else { return .incomplete }
        guard (0x40...0x7E).contains(rest[end]) else { return .notASequence }
        let parameters = String(decoding: rest[(rest.startIndex + 1)..<end], as: UTF8.self)
        let final = Character(UnicodeScalar(rest[end]))
        let length = end - index + 1
        if parameters.hasPrefix("<"), final == "M" || final == "m" {
            // An SGR mouse report: only the wheel matters. Shift, Option and Control add 4, 8 and 16.
            let button = Int(parameters.dropFirst().split(separator: ";").first ?? "") ?? -1
            return .key(Self.wheel(button), length)
        }
        if parameters.isEmpty, final == "M" {
            // An older mouse report: three bytes follow, the first the button plus 32.
            guard rest.endIndex - end > 3 else { return .incomplete }
            return .key(Self.wheel(Int(rest[end + 1]) - 32), length + 3)
        }
        // Modifiers come after a semicolon, as in Control-Up: the key is the same.
        let code = parameters.split(separator: ";").first.map(String.init) ?? ""
        switch (code, final) {
        case (_, "A") where code.isEmpty || code == "1": return .key(.up, length)
        case (_, "B") where code.isEmpty || code == "1": return .key(.down, length)
        case (_, "C") where code.isEmpty || code == "1": return .key(.right, length)
        case (_, "D") where code.isEmpty || code == "1": return .key(.left, length)
        case (_, "H") where code.isEmpty || code == "1": return .key(.home, length)
        case (_, "F") where code.isEmpty || code == "1": return .key(.end, length)
        case ("", "Z"): return .key(.backTab, length)
        case ("1", "~"), ("7", "~"): return .key(.home, length)
        case ("4", "~"), ("8", "~"): return .key(.end, length)
        case ("3", "~"): return .key(.delete, length)
        case ("5", "~"): return .key(.pageUp, length)
        case ("6", "~"): return .key(.pageDown, length)
        case ("200", "~"):
            pasting = []
            return .key(nil, length)
        default: return .key(nil, length)
        }
    }

    private static func wheel(_ button: Int) -> Key? {
        guard button >= 0 else { return nil }
        switch button & ~(4 | 8 | 16) {
        case 64: return .wheelUp
        case 65: return .wheelDown
        default: return nil
        }
    }
}
