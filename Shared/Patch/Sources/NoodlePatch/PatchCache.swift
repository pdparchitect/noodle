import Foundation

/// Patches read from attachments. An attachment's file never changes, so each is read once while
/// there is memory to keep it, and one that does not read as a patch is remembered as such.
@MainActor public enum PatchCache {
    private final class Entry {
        let patch: Patch?
        init(_ patch: Patch?) { self.patch = patch }
    }

    private static let entries: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()

    /// Read away from the main thread, for a card.
    public static func patch(at url: URL) async -> Patch? {
        if let entry = entries.object(forKey: url as NSURL) { return entry.patch }
        let patch = await Task.detached(priority: .utility) { Patch(contentsOf: url) }.value
        remember(patch, for: url)
        return patch
    }

    /// Read now, for an attachment someone is opening; its card has usually read it already.
    public static func patchNow(at url: URL) -> Patch? {
        if let entry = entries.object(forKey: url as NSURL) { return entry.patch }
        let patch = Patch(contentsOf: url)
        remember(patch, for: url)
        return patch
    }

    private static func remember(_ patch: Patch?, for url: URL) {
        // Read into lines and hunks, a patch takes a few times its size.
        let size = patch == nil ? 0 : (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        entries.setObject(Entry(patch), forKey: url as NSURL, cost: size * 4)
    }
}
