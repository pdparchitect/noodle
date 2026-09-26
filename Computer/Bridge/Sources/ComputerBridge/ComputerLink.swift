import Foundation

/// A link to a computer, and to the terminal or display a bot shared:
/// noodlecomputer://COMPUTER?terminal=TERMINAL&view=terminal|web. It carries no credentials or authority;
/// whoever opens it decides whether it may.
public enum ComputerLink {
    public static func url(computer: UUID, terminal: UUID?, view: String?, build: ComputerBuildIdentity = .current) -> URL {
        var parts = URLComponents()
        parts.scheme = build.urlScheme
        parts.host = computer.uuidString.lowercased()
        var items: [URLQueryItem] = []
        if let terminal { items.append(URLQueryItem(name: "terminal", value: terminal.uuidString.lowercased())) }
        if let view, ["terminal", "web"].contains(view) { items.append(URLQueryItem(name: "view", value: view)) }
        if !items.isEmpty { parts.queryItems = items }
        return parts.url!
    }
    public static func build(in url: URL) -> ComputerBuildIdentity? {
        ComputerBuildIdentity.allCases.first { $0.urlScheme == url.scheme?.lowercased() }
    }
    /// The computer, terminal and view a link names, in any build. Nil for anything else.
    public static func target(in url: URL) -> (computer: UUID, terminal: UUID?, view: String?)? {
        guard build(in: url) != nil, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty, parts.fragment == nil,
              let computer = parts.host.flatMap(UUID.init(uuidString:)) else { return nil }
        var terminal: UUID?, view: String?
        for item in parts.queryItems ?? [] {
            switch item.name {
            case "terminal" where terminal == nil:
                guard let value = item.value.flatMap(UUID.init(uuidString:)) else { return nil }
                terminal = value
            case "view" where view == nil:
                guard let value = item.value, ["terminal", "web"].contains(value) else { return nil }
                view = value
            default: return nil
            }
        }
        return (computer, terminal, view)
    }
}
