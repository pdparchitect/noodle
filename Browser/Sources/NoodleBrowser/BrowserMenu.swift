import AppKit
import BrowserBridge
import BrowserCore
import NoodleSettingsUI
import SwiftUI

struct BrowserMenu: View {
    @ObservedObject var library: BrowserLibrary
    let delegate: BrowserAppDelegate

    var body: some View {
        Button("Open Library") { delegate.reopenLibrary() }
        if !library.profiles.isEmpty { Divider() }
        ForEach(library.profiles) { profile in
            Button(profile.name) { delegate.showBrowser(profile.id) }
        }
        Divider()
        CompanionMenuSettingsButton()
        Button("Quit \(BrowserBuildIdentity.current.appName)") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
