import NoodleCore

/// The harnesses Rook is for. Security work stays with Codex, Claude and Apple Intelligence on this Mac: they are
/// on for a new install and offered by the welcome. The rest wait to be turned on in Settings.
public enum RookHarnesses {
    public static let featured: [HarnessProvider] = [.codex, .claudeCode, .apple]
    public static let onByDefault = Set(featured)
}
