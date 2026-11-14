import NoodleCore

/// The services Pion offers in Settings › Tools › Add Tools. Noodle's presets are reused as they are;
/// Pion's own security services join them here.
enum PionTools {
    static let catalogue: [ToolDefinition] = ToolCatalog.noodle
}
