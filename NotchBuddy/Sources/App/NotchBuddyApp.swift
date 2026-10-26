import SwiftUI
import AppKit

@main
struct NotchBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Before anything is localized: this fork runs in Spanish unless a language was picked.
        Brand.applyDefaultLanguage()
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
        #if !APPSTORE
        .commands {
            // ⌘, and Coucou → Settings… open the notch's pages of the Coucou window.
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("Settings…", comment: "")) {
                    delegate.openSettings()
                }
                .keyboardShortcut(",")
            }
        }
        #endif
    }
}
