import Foundation

/// Computer releases never use GitHub's repository-wide `latest` release,
/// which belongs to standard Noodle.
public enum ComputerDistribution {
    public static let downloadPage = URL(string: "https://github.com/pdparchitect/noodle/releases/tag/computer-latest")!
    public static let releaseAPI = URL(string: "https://api.github.com/repos/pdparchitect/noodle/releases/tags/computer-latest")!
    public static let documentation = URL(string: "https://github.com/pdparchitect/noodle/tree/main/Computer#build-and-run")!
    public static let feed = URL(string: "https://github.com/pdparchitect/noodle/releases/download/computer-latest/appcast.xml")!

    public static func validateDownloadStatus(_ status: Int) throws {
        if status == 404 {
            throw ComputerBridgeError("Noodle Computer does not have a public download yet. You can view the project and build instructions instead.")
        }
        guard status == 200 else { throw ComputerBridgeError("Computer downloads are temporarily unavailable. Try again later.") }
    }
}
