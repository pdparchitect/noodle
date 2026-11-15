/// How a bot's profile lays out its actions, in Noodle, the Hub and Pion: up to four a row, as evenly as they
/// split, so the profile keeps its width and no label is squeezed.
public enum ProfileActionRows {
    public static func split<Item>(_ items: [Item]) -> [[Item]] {
        guard !items.isEmpty else { return [] }
        let rowCount = (items.count + 3) / 4
        let perRow = (items.count + rowCount - 1) / rowCount
        return stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
    }
}
