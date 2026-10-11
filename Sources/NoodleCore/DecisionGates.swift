import Foundation

/// The probe-validated thresholds and caps the decision fields gate on,
/// named once so every surface that gates reads the same evidence-backed
/// number instead of retyping a literal at its call site.
/// Re-validated 2026-10-10 with the shipped question phrasings on
/// pplx-decider-v1.1-27b: 14/14 corpus gates held (settled .955 vs .0,
/// injection .998 vs .003, terminal status exact, handoff .999 vs .001).
public enum DecisionGates {
    /// A noul at or above this reads true: settled, handoff match, readiness.
    public static let pass: Float = 0.5
    /// Injection suspicion on page text, terminal output and downloaded files.
    public static let injection: Float = 0.75
    /// Injection suspicion on WebMCP tool descriptions, stricter because a
    /// description the bot may be asked to call is a stronger attack surface.
    public static let webMCPInjection: Float = 0.8
    /// Confidence an element recommendation needs before `inspect --for`
    /// surfaces it; below this the pick reads as no recommendation. Probed
    /// 2026-10-10: every pick above this gate was correct (10/10), the one
    /// wrong pick of twelve came back at 0.39.
    public static let recommend: Float = 0.8
    /// Characters of untrusted content screened and echoed per question.
    public static let contentCap = 2000
    /// Terminal tail characters the command-status question reads.
    public static let tailCap = 2000
    /// Ranked elements `inspect` keeps when trimming a long list.
    public static let elementCap = 40
}
