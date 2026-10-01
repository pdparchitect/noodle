#if NOODLE_DEV_HOOKS
import Foundation

/// Development builds only: Noodle as on a Mac that has never had it or any harness, to
/// walk through first-run setup with real downloads and real sign-ins. The app and its
/// Agent Host both find the folder in the app's Application Support, so its presence is
/// the switch. It holds the bots and a home of its own for every harness, out of reach
/// of the person's own installs, logins and login Keychain, and is emptied at each start.
public enum Rehearsal {
    public static func folder(in applicationSupport: URL) -> URL? {
        let folder = applicationSupport.appendingPathComponent("Rehearsal", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue ? folder : nil
    }

    public static func home(_ folder: URL) -> URL { folder.appendingPathComponent("Home", isDirectory: true) }
    public static func dataRoot(_ folder: URL) -> URL { folder.appendingPathComponent("Noodle", isDirectory: true) }

    /// Starts afresh, discarding whatever the previous rehearsal downloaded or signed in to.
    public static func begin(in applicationSupport: URL) throws {
        end(in: applicationSupport)
        let folder = applicationSupport.appendingPathComponent("Rehearsal", isDirectory: true)
        for created in [home(folder), dataRoot(folder)] {
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        }
    }

    public static func end(in applicationSupport: URL) {
        try? FileManager.default.removeItem(at: applicationSupport.appendingPathComponent("Rehearsal", isDirectory: true))
    }
}
#endif
