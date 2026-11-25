import Foundation

/// check-access as the tools reached with one key, token or key pair share it: each part the tool reads, tried once,
/// said as a line that starts ✓ with what it found or ✗ with what to change.
struct AccessCheck {
    /// What to say for each kind of refusal, in the service's own terms.
    struct Fixes: Sendable {
        /// The service did not accept the credentials (HTTP 401).
        var rejected: String
        /// The credentials may not read this part (HTTP 403).
        var forbidden: String
        /// Too many requests, or a quota spent (HTTP 429).
        var rateLimited = "the service is rate limiting this key, or its quota is used up: wait before trying again, or raise the plan's limit."
        /// The service could not be reached at all, such as a wrong host or a port a firewall closes.
        var unreachable = "Pion could not reach the service: check the address in Settings › Tools, and that this Mac may reach it."
        /// The service answered 404 where the part should be, such as an old version or a wrong region.
        var notFound: String? = nil
    }

    let fixes: Fixes
    private(set) var lines: [String] = []
    init(_ fixes: Fixes) { self.fixes = fixes }

    /// A line that is no check, such as which account or address is read.
    mutating func note(_ line: String) { lines.append("· " + line) }

    /// A part found to work without a probe of its own.
    mutating func pass(_ title: String, _ found: String) { lines.append("✓ \(title): \(found)") }

    /// A part found not to work without a request, such as a capability the account was seen to lack.
    mutating func fail(_ title: String, _ fix: String) { lines.append("✗ \(title): \(fix)") }

    /// Tries `body` once: ✓ with what it returns, or ✗ with what to change. Returns whether it worked.
    @discardableResult
    mutating func probe(_ title: String, forbidden: String? = nil, _ body: () async throws -> String) async -> Bool {
        do {
            let found = try await body()
            lines.append("✓ \(title)" + (found.isEmpty ? "" : ": \(found)"))
            return true
        } catch {
            fail(title, fix(for: error, forbidden: forbidden))
            return false
        }
    }

    /// What to change for `error`, with what the service said when it said anything.
    func fix(for error: Error, forbidden: String? = nil) -> String {
        func said(_ reason: String?) -> String { reason.map { " (it said: \($0))" } ?? "" }
        switch error {
        case ServiceError.rejected(let reason): return fixes.rejected + said(reason)
        case ServiceError.forbidden(let reason): return (forbidden ?? fixes.forbidden) + said(reason)
        case ServiceError.rateLimited(let reason): return fixes.rateLimited + said(reason)
        case ServiceError.notFound: return fixes.notFound ?? error.localizedDescription
        case is URLError: return fixes.unreachable
        default: return error.localizedDescription
        }
    }

    func result() throws -> ServiceResult {
        try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
    }

    /// A count, with its noun.
    static func count(_ number: Int, _ one: String, _ many: String) -> String { "\(number) \(number == 1 ? one : many)" }

    /// A whole number as services give them in JSON, often as a decimal.
    static func whole(_ value: Double?) -> String? { value.map { String(Int($0)) } }
}
