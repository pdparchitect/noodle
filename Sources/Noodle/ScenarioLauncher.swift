#if NOODLE_DEV_HOOKS
import AppKit
import CryptoKit
import SwiftUI

// What every app's scenarios share, whatever a scenario holds: choosing one, remembering the choice,
// reopening the bundle into it, the picker, the Scenarios menu and the clock times scenarios are written in.
// Nothing here knows an app's store or its scenario format. Development builds only.

struct ScenarioError: LocalizedError {
    let errorDescription: String?
    /// The scenario is sound but names media that scripts/scenario.sh has not fetched yet. A
    /// fresh checkout has none of it, so this is a scenario waiting for the script rather than a
    /// mistake in it.
    let needsFetch: Bool
    init(_ description: String, needsFetch: Bool = false) {
        errorDescription = description
        self.needsFetch = needsFetch
    }
}

/// A folder under the scenarios root, as the picker and the menu list it. A scenario that does not load keeps its
/// place and says why.
struct ScenarioListing: Identifiable {
    let name: String
    let folder: URL
    let title: String
    var summary: String?
    let error: String?
    /// Its media has not been fetched yet; the scenario itself is sound.
    var needsFetch: Bool = false
    var id: String { name }
}

@MainActor enum ScenarioLauncher {
    /// Where `scripts/scenario.sh` said the scenarios are, under the Info.plist key it wrote.
    static func scenariosRoot(key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Holds the name chosen in the app, in the container beside the run root. It stays until another choice replaces it,
    /// so Reload and opening the bundle again both return to the same scenario.
    static var pointerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("scenario-selection.txt")
    }

    /// The launch argument first, then the choice made in the app, unless the launch asks for the picker.
    static func selection(argument: String?, picker: Bool, pointer: URL) -> String? {
        if let argument { return argument }
        if picker { return nil }
        let chosen = (try? String(contentsOf: pointer, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen?.isEmpty == false ? chosen : nil
    }

    static func select(_ name: String?, pointer: URL) throws {
        guard let name else { try? FileManager.default.removeItem(at: pointer); return }
        try FileManager.default.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: pointer, options: .atomic)
    }

    static func folder(for selection: String, root: URL?) -> URL? {
        selection.contains("/") ? URL(fileURLWithPath: selection, isDirectory: true) : root?.appendingPathComponent(selection, isDirectory: true)
    }

    /// Every folder under `root` with a scenario.json, each read with `load` for its title and summary.
    static func listings(in root: URL?, load: (URL) throws -> (title: String, summary: String?)) -> [ScenarioListing] {
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

    /// A sandboxed app cannot pass itself launch arguments, so the choice travels in the pointer file.
    /// Launch Services will not open a second instance of it either, so the bundle reopens once this one has quit.
    static func relaunch(into name: String?) {
        do {
            try select(name, pointer: pointerURL)
            let reopener = try reopener(of: Bundle.main.bundleURL, with: "/usr/bin/open")
            try reopener.process.run()
            whileRunning = reopener.whileRunning
            NSApp.terminate(nil)
        } catch { NSSound.beep() }
    }

    /// Held open until the app quits, which is what tells the reopener to go ahead.
    private static var whileRunning: FileHandle?

    /// A shell job in a process group of its own, so it outlives the app, that waits for `whileRunning` to close.
    nonisolated static func reopener(of bundle: URL, with opener: String) throws -> (process: Process, whileRunning: FileHandle) {
        let pipe = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 3<&0; set -m; (cat <&3 > /dev/null; sleep 0.3; exec \"$0\" \"$1\") > /dev/null 2>&1 &", opener, bundle.path]
        process.standardInput = pipe
        return (process, pipe.fileHandleForWriting)
    }

    private static var pickerWindow: NSWindow?

    /// The picker, which stands in for the main window while no scenario is loaded.
    static func showPicker(_ listings: [ScenarioListing]) {
        if pickerWindow == nil {
            let controller = NSHostingController(rootView: ScenarioPicker(listings: listings))
            // A window takes its title from its content view controller.
            controller.title = "Scenarios"
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 400))
            window.center()
            pickerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        pickerWindow?.makeKeyAndOrderFront(nil)
    }

    static func isPicker(_ window: NSWindow) -> Bool { window === pickerWindow }
}

private struct ScenarioPicker: View {
    let listings: [ScenarioListing]
    @State private var selection: String?

    private var canLoad: Bool { listings.contains { $0.name == selection && $0.error == nil } }

    var body: some View {
        VStack(spacing: 0) {
            List(listings, selection: $selection) { listing in
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.title)
                    Text(listing.error ?? listing.summary ?? listing.name)
                        .font(.caption)
                        .foregroundStyle(listing.error == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { names in
                if let name = names.first, listings.contains(where: { $0.name == name && $0.error == nil }) {
                    ScenarioLauncher.relaunch(into: name)
                }
            }
            .overlay {
                if listings.isEmpty { Text("No scenarios found").foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Load") { ScenarioLauncher.relaunch(into: selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canLoad)
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 260)
        .preferredColorScheme(.dark)
    }
}

/// The Scenarios menu, which only the scenarios bundle shows: each scenario, Reload, Next Step, the picker and Finder.
struct ScenarioMenu: Commands {
    let listings: [ScenarioListing]
    /// The folder of the scenario loaded now, if one is.
    let loaded: URL?
    let selection: String?
    let nextStep: () -> Void
    let showPicker: () -> Void
    let reveal: () -> Void

    var body: some Commands {
        CommandMenu("Scenarios") {
            ForEach(listings) { listing in
                Toggle(listing.title, isOn: Binding(
                    get: { listing.folder.standardizedFileURL.path == loaded?.standardizedFileURL.path },
                    set: { _ in ScenarioLauncher.relaunch(into: listing.name) }))
                    .disabled(listing.error != nil)
            }
            Divider()
            Button("Reload") { ScenarioLauncher.relaunch(into: selection) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(selection == nil)
            Button("Next Step", action: nextStep)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Button("Show Picker", action: showPicker)
            Button("Reveal in Finder", action: reveal)
        }
    }
}

enum ScenarioTime {
    /// The clock a scenario opens at: `HH:mm` today, or the wall clock.
    static func start(_ clock: String?, now: Date, calendar: Calendar = .current) throws -> Date {
        guard let clock else { return now }
        guard !clock.contains(" "), !clock.hasPrefix("-") else { throw ScenarioError("clock is a time such as \"09:41\".") }
        return try date(clock, clock: now, calendar: calendar)
    }

    /// `HH:mm` on the scenario's day, `-Nd HH:mm` on an earlier day, or `-Nm` and `-Nh` before the clock.
    static func date(_ text: String, clock: Date, calendar: Calendar = .current) throws -> Date {
        func time(_ value: Substring, daysAgo: Int) -> Date? {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard value.count == 5, fields.count == 2, (0..<24).contains(fields[0]), (0..<60).contains(fields[1]),
                  let day = calendar.date(byAdding: .day, value: -daysAgo, to: clock) else { return nil }
            return calendar.date(bySettingHour: fields[0], minute: fields[1], second: 0, of: day)
        }
        func ago(_ value: Substring, _ unit: Character) -> Int? {
            value.first == "-" && value.last == unit ? Int(value.dropFirst().dropLast()).flatMap { $0 >= 0 ? $0 : nil } : nil
        }
        let parts = text.split(separator: " ")
        if parts.count == 1 {
            if let date = time(parts[0], daysAgo: 0) { return date }
            if let minutes = ago(parts[0], "m") { return clock.addingTimeInterval(-60 * Double(minutes)) }
            if let hours = ago(parts[0], "h") { return clock.addingTimeInterval(-3600 * Double(hours)) }
        } else if parts.count == 2, let days = ago(parts[0], "d"), let date = time(parts[1], daysAgo: days) {
            return date
        }
        throw ScenarioError("\"\(text)\" is not a time: use \"HH:mm\", \"-2d HH:mm\", \"-15m\" or \"-3h\".")
    }
}

/// The line protocol with scripts/scenario.sh. The app writes a line; where the script must act first, as when it
/// photographs a shot, it answers with a newline. A newline nobody waits for is Next Step. Launch Services attaches
/// no terminal, so the input ends at once, nothing waits for an answer again, and only the menu is left.
@MainActor final class ScenarioTerminal {
    private var answerWaiters: [CheckedContinuation<Void, Never>] = []
    private var keyWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var ended = true

    /// The timeline is stopped until Next Step or a newline from the terminal.
    var isWaitingForKey: Bool { !keyWaiters.isEmpty }

    func write(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }

    /// Waits for the script's newline, unless the terminal is gone.
    func awaitAnswer() async {
        guard !ended else { return }
        await withCheckedContinuation { answerWaiters.append($0) }
    }

    func awaitKey() async {
        await withCheckedContinuation { keyWaiters.append($0) }
    }

    /// Scenarios > Next Step, or a newline nobody waited for.
    func nextStep() {
        let waiters = keyWaiters
        keyWaiters = []
        waiters.forEach { $0.resume() }
    }

    func start() {
        ended = false
        Task { @MainActor in
            do {
                // Every newline counts, which the line sequence would not say of an empty line.
                for try await byte in FileHandle.standardInput.bytes where byte == 10 {
                    if let waiter = self.answerWaiters.first { self.answerWaiters.removeFirst(); waiter.resume() }
                    else { self.nextStep() }
                }
            } catch {}
            self.ended = true
            let waiters = self.answerWaiters
            self.answerWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
}

// MARK: - Shared pieces

enum ScenarioSupport {
    /// Keys of `original` that did not survive decoding and encoding again. Null values are skipped, as encoding omits them.
    static func unknownKeys(in original: Any, comparedTo encoded: Any?, path: String = "") -> [String] {
        if let original = original as? [String: Any] {
            let encoded = encoded as? [String: Any] ?? [:]
            return original.keys.sorted().flatMap { key -> [String] in
                guard !(original[key] is NSNull) else { return [] }
                let here = path.isEmpty ? key : "\(path).\(key)"
                return encoded[key] == nil ? [here] : unknownKeys(in: original[key]!, comparedTo: encoded[key], path: here)
            }
        }
        if let original = original as? [Any] {
            let encoded = encoded as? [Any] ?? []
            return original.enumerated().flatMap { index, value in
                unknownKeys(in: value, comparedTo: encoded.indices.contains(index) ? encoded[index] : nil, path: "\(path)[\(index)]")
            }
        }
        return []
    }

    /// A picture or video a scenario names: an asset in its own folder, or a web address
    /// that scripts/scenario.sh has fetched into the `.cache` beside the scenarios. The
    /// bundle has no network of its own, so nothing is ever downloaded from in here.
    static func media(_ value: String, in folder: URL) throws -> URL {
        guard isRemote(value) else { return try file(value, under: folder) }
        // One cache for all of them: the name is the address, so two scenarios naming the
        // same thing share the one copy. Found by name rather than by extension, because a
        // web address need not end in one and the script works out what it is.
        let stem = cacheStem(for: value)
        let cache = folder.deletingLastPathComponent().appendingPathComponent(".cache", isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(stem) }
        guard let found else {
            throw ScenarioError(
                "\(value) has not been fetched yet. scripts/scenario.sh downloads it beside the scenarios.",
                needsFetch: true)
        }
        return found
    }

    static func isRemote(_ value: String) -> Bool {
        value.hasPrefix("https://") || value.hasPrefix("http://")
    }

    /// What a fetched address is called on disk, before its extension. The script names
    /// downloads the same way, so changing this strands every cache.
    static func cacheStem(for address: String) -> String {
        String(SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// A file named by a scenario, kept inside `root` however the name is written.
    static func file(_ path: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else {
            throw ScenarioError("Missing asset: \(path)")
        }
        return url
    }

    static var screen: NSRect { NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080) }

    /// Scenario frames are `[x, y, width, height]` from the top left of the main screen.
    static func rect(_ frame: [Double]) -> NSRect {
        NSRect(x: screen.minX + frame[0], y: screen.maxY - frame[1] - frame[3], width: frame[2], height: frame[3])
    }

    /// The text form AppKit saves a window frame in, which is what conversation windows are restored from.
    static func frameDescriptor(_ frame: [Double]) -> String {
        let rect = rect(frame), screen = screen
        return [rect.minX, rect.minY, rect.width, rect.height, screen.minX, screen.minY, screen.width, screen.height]
            .map { String(Int($0)) }.joined(separator: " ") + " "
    }

    /// Grows `box` to the shape of `like` and keeps it within `bounds`, so a move in on
    /// it never stretches the picture and never reaches past what it is allowed to show.
    static func fit(_ box: NSRect, shapedLike like: NSRect, inside bounds: NSRect) -> NSRect {
        let shape = like.width / like.height
        var width = box.width, height = box.height
        if width / height > shape { height = width / shape } else { width = height * shape }
        if width > bounds.width { width = bounds.width; height = width / shape }
        if height > bounds.height { height = bounds.height; width = height * shape }
        let x = min(max(box.midX - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(box.midY - height / 2, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// A mark drawn in one colour, redrawn in another. Only its shape is kept, so a
    /// black logo can be shown on a dark card without disappearing into it.
    static func tinted(_ image: NSImage, _ colour: String) -> NSImage {
        let ink: NSColor = colour == "black" ? .black : .white
        let box = NSRect(origin: .zero, size: image.size)
        let result = NSImage(size: image.size)
        result.lockFocus()
        ink.set()
        box.fill()
        image.draw(in: box, from: .zero, operation: .destinationIn, fraction: 1)
        result.unlockFocus()
        return result
    }

    /// A mark drawn to its own edges is sliced by the circle it is shown in, so one is
    /// given room around it. A photograph is left alone: it is meant to fill the circle.
    static func roomAround(_ image: NSImage) -> NSImage {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              bitmap.hasAlpha, bitmap.pixelsWide > 8, bitmap.pixelsHigh > 8 else { return image }
        var clear = 0, counted = 0
        for step in 0..<64 {
            let alongX = bitmap.pixelsWide * step / 64, alongY = bitmap.pixelsHigh * step / 64
            for point in [(alongX, 0), (alongX, bitmap.pixelsHigh - 1), (0, alongY), (bitmap.pixelsWide - 1, alongY)] {
                counted += 1
                if (bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 1) < 0.1 { clear += 1 }
            }
        }
        guard counted > 0, Double(clear) / Double(counted) > 0.8 else { return image }

        let side = max(image.size.width, image.size.height) / 0.66
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        image.draw(in: NSRect(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2,
                              width: image.size.width, height: image.size.height))
        canvas.unlockFocus()
        return canvas
    }

    /// The first view anywhere under `view` that matches, breadth first.
    static func firstView(in view: NSView?, matching: (NSView) -> Bool) -> NSView? {
        guard let view else { return nil }
        var pending = [view]
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if matching(next) { return next }
            pending.append(contentsOf: next.subviews)
        }
        return nil
    }

    static func splitController(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController { return controller }
        return view.subviews.lazy.compactMap { splitController(in: $0) }.first
    }
}
#endif
