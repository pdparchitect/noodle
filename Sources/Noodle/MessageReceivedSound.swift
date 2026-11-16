import AppKit
import Foundation
import UserNotifications

/// The sound for a bot's reply, as in Messages: the notification plays it while Noodle is in the
/// background, Noodle plays it itself while in front, whichever conversation is open.
enum MessageReceivedSound {
    static let defaultsKey = "messageReceivedSound"
    static let none = ""
    static let defaultName = "Blow"
    /// The alert sounds in /System/Library/Sounds, which apps may play by name.
    static let names = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    static func selected(in defaults: UserDefaults = .standard) -> String? {
        let name = defaults.string(forKey: defaultsKey) ?? defaultName
        return names.contains(name) ? name : nil
    }

    static func playsInApp(newMessages: Int, presentsNotifications: Bool) -> Bool {
        newMessages > 0 && !presentsNotifications
    }

    /// New replies arrived: the sound plays here when no notification will play it. True when notifications show.
    @MainActor
    static func announce(newMessages: Int) -> Bool {
        let presents = AgentNotifications.shouldPresentActivity
        if playsInApp(newMessages: newMessages, presentsNotifications: presents) { play() }
        return presents
    }

    @MainActor
    static func play(in defaults: UserDefaults = .standard) {
        guard let name = selected(in: defaults) else { return }
        NSSound(named: name)?.play()
    }

    /// Notifications only find sounds in the app's own Library/Sounds, so the chosen system
    /// sound is copied there first; the system still applies Focus and the per-app sound switch.
    static func notificationSound(
        in defaults: UserDefaults = .standard,
        soundsDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
    ) -> UNNotificationSound? {
        guard let name = selected(in: defaults) else { return nil }
        let file = "\(name).aiff"
        let copy = soundsDirectory.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: copy.path) {
            do {
                try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: "/System/Library/Sounds").appendingPathComponent(file),
                    to: copy
                )
            } catch {
                return .default
            }
        }
        return UNNotificationSound(named: UNNotificationSoundName(file))
    }
}
