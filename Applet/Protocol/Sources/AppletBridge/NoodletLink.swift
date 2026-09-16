import Foundation

public enum NoodletLink {
    public static func url(for id: UUID) -> URL { url(for: id, build: .current) }
    public static func url(for id: UUID, build: AppletBuildIdentity) -> URL {
        URL(string: build.urlScheme + "://" + id.uuidString.lowercased())!
    }
    /// Recognition preserves both channels so a foreign link can be displayed with
    /// an unavailable message. Opening/access must additionally call requireID.
    public static func build(in url: URL) -> AppletBuildIdentity? {
        AppletBuildIdentity.allCases.first { $0.urlScheme == url.scheme?.lowercased() }
    }
    public static func id(in url: URL) -> UUID? {
        guard let build = build(in: url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              let host = parts.host, let id = UUID(uuidString: host),
              url.absoluteString.lowercased() == self.url(for: id, build: build).absoluteString
        else { return nil }
        return id
    }
    public static func canonical(_ url: URL) -> URL? {
        guard let build = build(in: url), let id = id(in: url) else { return nil }
        return self.url(for: id, build: build)
    }
    public static func requireID(in url: URL, build: AppletBuildIdentity = .current) throws -> UUID {
        guard let id = id(in: url) else { throw AppletError("Invalid noodlet link.") }
        guard self.build(in: url) == build else {
            throw AppletError("This noodlet belongs to the other environment and is unavailable in \(build.appName).", code: "environment-mismatch")
        }
        return id
    }
}
