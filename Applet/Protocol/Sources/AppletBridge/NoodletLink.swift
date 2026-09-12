import Foundation

public enum NoodletLink {
    public static func url(for id: UUID) -> URL {
        URL(string: "noodlet://" + id.uuidString.lowercased())!
    }

    public static func id(in url: URL) -> UUID? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "noodlet", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil,
              let host = parts.host, let id = UUID(uuidString: host),
              url.absoluteString.lowercased() == self.url(for: id).absoluteString
        else { return nil }
        return id
    }
}
