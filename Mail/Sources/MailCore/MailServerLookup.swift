import Foundation

/// What one HTTPS request got: a body, a definite "not here" (any status but 200, or too big), or no answer.
public enum MailFetch: Equatable, Sendable { case data(Data), missing, failed }

/// The two questions Find Servers asks the network. Tests answer them from memory.
public protocol MailLookupNetwork: Sendable {
    func fetch(_ url: URL) async -> MailFetch
    /// The domain's mail servers, best first: nil when DNS couldn't be asked or gave no answer, [] when the answer held
    /// none. The live network can't tell a domain without MX from a failure, so it answers nil for both.
    func mailExchangers(for domain: String) async -> [String]?
}

/// What Find Servers found, and the sentence the mailbox form shows for it.
public enum MailServerLookupResult: Equatable, Sendable {
    case found(MailServerSettings, domain: String, provider: String?)
    case oauthOnly(domain: String)
    case notFound(domain: String)
    case unreachable(domain: String)
    case invalidAddress

    public var message: String {
        switch self {
        case .found(_, let domain, let provider?): return "Found the servers for \(domain) at \(provider). Check them, then Save."
        case .found(_, let domain, nil): return "Found the servers for \(domain). Check them, then Save."
        case .oauthOnly(let domain): return "\(domain) only allows signing in through its own web page (OAuth), which Noodle Mail can't do yet."
        case .notFound(let domain): return "No server settings found for \(domain). Enter them below; your provider's help pages list them."
        case .unreachable(let domain): return "Couldn't look up the servers for \(domain). Check the connection, or enter them below."
        case .invalidAddress: return "Enter the e-mail address first."
        }
    }
}

/// Finds a mailbox's servers the way Thunderbird does: the domain's own settings, Mozilla's list, then the
/// provider behind the domain's mail servers. Only the domain is ever sent.
public struct MailServerLookup: Sendable {
    let network: MailLookupNetwork
    public init(network: MailLookupNetwork) { self.network = network }
    /// Asks the real network.
    public init() { self.init(network: MailLookupLiveNetwork()) }

    public func find(address: String) async -> MailServerLookupResult {
        guard let domain = Self.domain(of: address) else { return .invalidAddress }
        var answered = false
        func ask(_ url: URL) async -> MailAutoconfig.Result? {
            switch await network.fetch(url) {
            case .data(let data): answered = true; return MailAutoconfig.parse(data, domain: domain)
            case .missing: answered = true; return nil
            case .failed: return nil
            }
        }
        for url in Self.domainURLs(domain) {
            switch await ask(url) {
            case .settings(let settings)?: return .found(settings, domain: domain, provider: nil)
            case .oauthOnly?: return .oauthOnly(domain: domain)
            case .unusable?, nil: continue
            }
        }
        if let exchangers = await network.mailExchangers(for: domain) {
            answered = true
            for provider in exchangers.first.map({ Self.providerDomains(of: $0, excluding: domain) }) ?? [] {
                switch await ask(Self.mozillaURL(provider)) {
                case .settings(let settings)?: return .found(settings, domain: domain, provider: provider)
                case .oauthOnly?: return .oauthOnly(domain: domain)
                case .unusable?, nil: continue
                }
            }
        }
        return answered ? .notFound(domain: domain) : .unreachable(domain: domain)
    }

    /// The part after the last @, trimmed and lowercased, if it is a host name.
    static func domain(of address: String) -> String? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = address.lastIndex(of: "@"), at != address.startIndex else { return nil }
        let domain = String(address[address.index(after: at)...])
        return MailAutoconfig.isHostName(domain) ? domain : nil
    }

    static func domainURLs(_ domain: String) -> [URL] {
        ["https://autoconfig.\(domain)/mail/config-v1.1.xml", "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml"]
            .compactMap(URL.init(string:)) + [mozillaURL(domain)]
    }

    static func mozillaURL(_ domain: String) -> URL { URL(string: "https://autoconfig.thunderbird.net/v1.1/\(domain)")! }

    /// A mail server's parent domains, longest first, at most the three nearest the top: the first label
    /// names a machine, not a provider (…mx2.emailprofi.seznam.cz → mx2.emailprofi.seznam.cz, emailprofi.seznam.cz, seznam.cz).
    static func providerDomains(of host: String, excluding domain: String) -> [String] {
        let labels = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").map(String.init)
        guard labels.count > 2 else { return [] }
        let parents = (1...(labels.count - 2)).map { labels[$0...].joined(separator: ".") }
        return parents.suffix(3).filter { $0 != domain && MailAutoconfig.isHostName($0) }
    }
}
