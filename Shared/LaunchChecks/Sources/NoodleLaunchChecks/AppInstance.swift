import AppKit
import Darwin

/// Keeps one copy of each app build running. macOS already brings a running app forward when it
/// is opened again, but not when it is opened with `open -n`, from another copy of the bundle or by
/// running its executable; a second copy would then share the first one's data.
public enum AppInstance {
    nonisolated(unsafe) private static var lease: Int32 = -1

    /// Call at launch, before the app opens its data. A second copy brings the first one forward
    /// and quits. Launches with test options or a command are left alone: they run beside the app.
    @MainActor public static func claim(arguments: [String] = CommandLine.arguments) {
        guard lease < 0, isGuarded(arguments), let bundle = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        if let descriptor = lock(in: caches.appendingPathComponent(bundle, isDirectory: true)) {
            lease = descriptor
            return
        }
        if !arguments.contains(background) {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                .first { $0.processIdentifier != getpid() }?.activate()
        }
        exit(0)
    }

    private static let background = "--noodle-background"

    static func isGuarded(_ arguments: [String]) -> Bool {
        arguments.dropFirst().allSatisfy { $0 == background }
    }

    /// The descriptor holding the lock in `folder`, or nil when another process holds it.
    static func lock(in folder: URL) -> Int32? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent("Instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}
