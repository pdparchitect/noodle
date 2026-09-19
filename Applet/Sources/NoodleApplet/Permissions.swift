import AVFoundation
import AppKit
import AppletCore
import Speech

/// Asks once per noodlet for the permissions its manifest declares, then lets
/// macOS ask for Applet as a whole.
@MainActor enum AppletPermissions {
  private static let names = [
    "microphone": "the microphone", "camera": "the camera", "speech-recognition": "speech recognition",
    "screen-capture": "screen recording",
  ]

  /// Returns why the noodlet may not start, or nil when everything it declares is allowed.
  static func authorize(_ package: NoodletPackage, defaults: UserDefaults) async -> String? {
    let wanted = Set(package.manifest.permissions ?? [])
    guard !wanted.isEmpty else { return nil }
    let key = "permissions.\(package.key)"
    if !wanted.isSubset(of: Set(defaults.stringArray(forKey: key) ?? [])) {
      let alert = NSAlert()
      alert.messageText =
        "“\(package.manifest.title)” would like to use \(wanted.sorted().compactMap { names[$0] }.joined(separator: " and "))."
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Don’t Allow")
      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else {
        return "Permission was not given to use \(wanted.sorted().joined(separator: ", "))."
      }
      defaults.set(wanted.sorted(), forKey: key)
    }
    if wanted.contains("microphone"), await !AVCaptureDevice.requestAccess(for: .audio) {
      return "Microphone access is off for Noodle Applet in System Settings > Privacy & Security."
    }
    if wanted.contains("camera"), await !AVCaptureDevice.requestAccess(for: .video) {
      return "Camera access is off for Noodle Applet in System Settings > Privacy & Security."
    }
    // macOS applies a new screen recording grant only after the app restarts.
    if wanted.contains("screen-capture"), !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
      return "Allow Noodle Applet in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen Noodle Applet."
    }
    if wanted.contains("speech-recognition") {
      let status = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
      }
      if status != .authorized {
        return "Speech recognition is off for Noodle Applet in System Settings > Privacy & Security."
      }
    }
    return nil
  }
}
