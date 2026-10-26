import Foundation

// MARK: - Brand
// Pure Foundation: also compiled into the standalone voice test scripts.

/// The name this copy of Coucou shows. Abraham's fork calls it "Jarvis" in what the user
/// sees and hears (menu, notch, Settings, voice). What other things depend on keeps
/// "Coucou": the bundle identifier, the Keychain service, the App Group, file and folder
/// names, hook identifiers and the GitHub releases the updater follows.
/// The catalog (Localizable.xcstrings) carries the same name: after a rebase on upstream,
/// `python3 scripts/jarvis-brand.py` rewrites its new strings from this value.
enum Brand {
    static let name = "Jarvis"

    /// Spanish by default: on the first launch of this fork, when no language was picked in
    /// Settings → Language, the app runs in Spanish. Picking another one (System included)
    /// afterwards sticks. Called before anything is localized (NotchBuddyApp.init).
    static func applyDefaultLanguage(_ defaults: UserDefaults = .standard,
                                     bundleId: String = Bundle.main.bundleIdentifier ?? "fr.louisraille.NotchBuddy") {
        let doneKey = "jarvisDefaultLanguageApplied"
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        if defaults.persistentDomain(forName: bundleId)?["AppleLanguages"] == nil {
            defaults.set(["es"], forKey: "AppleLanguages")
        }
    }
}
