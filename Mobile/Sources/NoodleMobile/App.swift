import SwiftUI

@main
struct NoodleMobileApp: App {
    var body: some Scene {
        WindowGroup {
            Image("Symbol")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Noodle")
        }
    }
}
