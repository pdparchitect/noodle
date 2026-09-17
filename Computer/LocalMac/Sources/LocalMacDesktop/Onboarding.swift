import Foundation
import LocalMacCore
import Darwin

/// Prepare the managed user's unattended desktop. Run as that user, including
/// before the first GUI login; never write a root-owned user template.
func prepareOnboarding(_ account: LocalMacAccount) throws {
    try account.validate(owner: account.ownerUID)
    guard getuid() == account.uid, geteuid() == account.uid,
          NSUserName() == account.name, let entry = getpwuid(account.uid),
          String(cString: entry.pointee.pw_dir) == account.home else {
        throw LocalMacError("Onboarding preparation requires the assigned standard account.")
    }
    // A background desktop has no physical HID activity, so its default screen
    // saver eventually locks even while the client sends synthetic input.
    // Disable that idle trigger for this user only. Do not hold a system-wide
    // power assertion or change password requirements, manual locking, or sleep.
    let screensaver = "com.apple.screensaver" as CFString
    for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
        CFPreferencesSetValue("idleTime" as CFString, 0 as CFNumber,
            screensaver, kCFPreferencesCurrentUser, host)
        guard CFPreferencesSynchronize(screensaver, kCFPreferencesCurrentUser, host),
              (CFPreferencesCopyValue("idleTime" as CFString, screensaver,
                kCFPreferencesCurrentUser, host) as? NSNumber)?.intValue == 0 else {
            throw LocalMacError("Cannot disable the managed account's idle screen saver.")
        }
    }
    guard let identity = LocalMacIdentity.desktop(Bundle.main.bundleIdentifier) else {
        throw LocalMacError("Cannot identify this account's desktop helper for shell setup.")
    }
    try LocalMacShellWelcome.prepare(home: account.home, identity: identity)
    let marker = account.home + "/.skipbuddy"
    let fd = Darwin.open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if fd >= 0 { Darwin.close(fd) }
    else {
        var info = stat()
        guard errno == EEXIST, lstat(marker, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == account.uid else { throw LocalMacError("Cannot prepare this account's onboarding marker.") }
    }
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
    guard let version = info?["ProductVersion"] as? String,
          let build = info?["ProductBuildVersion"] as? String else {
        throw LocalMacError("Cannot identify this macOS build for account preparation.")
    }
    let domain = "com.apple.SetupAssistant" as CFString
    let seen = ["DidSeeAccessibility", "DidSeeActivationLock", "DidSeeAppStore", "DidSeeAppearanceSetup",
        "DidSeeApplePaySetup", "DidSeeCloudSetup", "DidSeeLockdownMode", "DidSeePrivacy", "DidSeeScreenTime",
        "DidSeeSiriSetup", "DidSeeSyncSetup", "DidSeeSyncSetup2", "DidSeeTermsOfAddress", "DidSeeTouchIDSetup",
        "DidSeeiCloudLoginForStorageServices"]
    let versions = ["LastPreLoginTasksPerformedVersion", "LastSeenAgeRangeSelectionProductVersion", "LastSeenCloudProductVersion",
        "LastSeenDiagnosticsProductVersion", "LastSeenIntelligenceProductVersion", "LastSeenSiriProductVersion",
        "LastSeenSyncProductVersion", "LastSeeniCloudStorageServicesProductVersion", "DidSeeNewFeaturesProductVersion"]
    var values = Dictionary(uniqueKeysWithValues: seen.map { ($0, true as Any) })
    for key in versions { values[key] = version }
    values["LastSeenBuddyBuildVersion"] = build
    // These are presentation-history preferences, not service opt-ins, grants,
    // agreement acceptance, MDM settings, or the machine's .AppleSetupDone marker.
    CFPreferencesSetMultiple(values as CFDictionary, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
        throw LocalMacError("Cannot save this account's onboarding preferences.")
    }
}
