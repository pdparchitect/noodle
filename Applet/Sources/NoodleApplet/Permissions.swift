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

  static let titles = [
    "microphone": "Microphone", "camera": "Camera", "speech-recognition": "Speech Recognition",
    "screen-capture": "Screen Recording",
  ]
  private static func key(_ package: NoodletPackage) -> String { "permissions.\(package.key)" }

  /// granted needs both the user's answer for this noodlet and macOS's for Applet.
  static func status(_ package: NoodletPackage, defaults: UserDefaults) -> [String: String]? {
    guard let wanted = package.manifest.permissions, !wanted.isEmpty else { return nil }
    let agreed = Set(defaults.stringArray(forKey: key(package)) ?? [])
    return Dictionary(uniqueKeysWithValues: wanted.map { permission in
      let system: Bool? =
        switch permission {
        case "microphone": allowed(AVCaptureDevice.authorizationStatus(for: .audio))
        case "camera": allowed(AVCaptureDevice.authorizationStatus(for: .video))
        case "speech-recognition":
          switch SFSpeechRecognizer.authorizationStatus() {
          case .authorized: true
          case .notDetermined: nil
          default: false
          }
        // macOS does not say whether screen recording was refused or never asked.
        default: CGPreflightScreenCaptureAccess() ? true : nil
        }
      if system == false { return (permission, "denied") }
      return (permission, system == true && agreed.contains(permission) ? "granted" : "not-requested")
    })
  }
  private static func allowed(_ status: AVAuthorizationStatus) -> Bool? {
    switch status {
    case .authorized: true
    case .notDetermined: nil
    default: false
    }
  }
  /// What the user has agreed to, by package key.
  static func grants(defaults: UserDefaults) -> [String: [String]] {
    var grants: [String: [String]] = [:]
    for (name, value) in defaults.dictionaryRepresentation() where name.hasPrefix("permissions.") {
      if let permissions = value as? [String], !permissions.isEmpty {
        grants[String(name.dropFirst("permissions.".count))] = permissions
      }
    }
    return grants
  }
  static func revoke(packageKey: String, defaults: UserDefaults) {
    defaults.removeObject(forKey: "permissions.\(packageKey)")
  }

  /// Returns why the noodlet may not start, or nil when everything it declares is allowed.
  static func authorize(_ package: NoodletPackage, defaults: UserDefaults) async -> String? {
    let wanted = Set(package.manifest.permissions ?? [])
    guard !wanted.isEmpty else { return nil }
    let key = key(package)
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
