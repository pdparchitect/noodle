#if NOODLE_DEV_HOOKS
import Foundation

/// A folder under the scenarios root, as the picker and the menu list it. A scenario that does not load keeps its
/// place and says why.
public struct ScenarioListing: Identifiable {
    public let name: String
    public let folder: URL
    public let title: String
    public var summary: String?
    public let error: String?
    /// Its media has not been fetched yet; the scenario itself is sound.
    public var needsFetch: Bool = false
    public var id: String { name }

    public init(name: String, folder: URL, title: String, summary: String? = nil, error: String?, needsFetch: Bool = false) {
        self.name = name
        self.folder = folder
        self.title = title
        self.summary = summary
        self.error = error
        self.needsFetch = needsFetch
    }

    /// Every folder under `root` with a scenario.json, each read with `load` for its title and summary.
    public static func all(in root: URL?, load: (URL) throws -> (title: String, summary: String?)) -> [ScenarioListing] {
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("scenario.json")) else { return nil }
            do {
                let loaded = try load(folder)
                return ScenarioListing(name: name, folder: folder.standardizedFileURL, title: loaded.title, summary: loaded.summary, error: nil)
            } catch {
                let title = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["title"] as? String
                return ScenarioListing(name: name, folder: folder.standardizedFileURL, title: title ?? name, error: error.localizedDescription,
                                       needsFetch: (error as? ScenarioError)?.needsFetch == true)
            }
        }
    }
}
#endif
