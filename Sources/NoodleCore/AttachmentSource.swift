import Foundation
import AppletBridge

public enum AttachmentSource {
    public struct InvalidSource: LocalizedError {
        public var errorDescription: String? {
            "Attach a local file path, file:/// URL, public HTTP/HTTPS URL, or noodlet:// UUID link."
        }
    }

    public static func resolve(_ value: String, relativeTo directory: URL) throws -> URL {
        guard !value.isEmpty else { throw InvalidSource() }
        if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() {
            switch scheme {
            case "noodlet":
                guard let url = components.url, let id = NoodletLink.id(in: url) else { throw InvalidSource() }
                return NoodletLink.url(for: id)
            case "http", "https":
                guard let url = components.url, let safe = MessageLink.publicWebURL(from: url, preservingFragment: true) else {
                    throw InvalidSource()
                }
                return safe
            case "file":
                guard components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
                      components.user == nil, components.password == nil, components.port == nil,
                      components.query == nil, components.fragment == nil,
                      components.path.hasPrefix("/"), let url = components.url, url.isFileURL else { throw InvalidSource() }
                return URL(fileURLWithPath: url.path).standardizedFileURL
            default: throw InvalidSource()
            }
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
    }
}
