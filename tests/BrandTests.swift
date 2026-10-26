import Foundation

// MARK: - Brand tests (this fork's name and default language)

@main
enum BrandTests {
    static var failures = 0
    static var total = 0

    static func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("✓  \(label)") } else { print("✗  \(label) \(detail())"); failures += 1 }
    }

    static func fresh(_ name: String) -> (UserDefaults, String) {
        let suite = "jarvis-brand-tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    static func main() {
        check("name", Brand.name == "Jarvis")

        var (d, suite) = fresh("first")
        Brand.applyDefaultLanguage(d, bundleId: suite)
        check("first launch: Spanish", d.stringArray(forKey: "AppleLanguages") == ["es"],
              "\(String(describing: d.stringArray(forKey: "AppleLanguages")))")

        // Then the user picks System in Settings → Language (the key is removed): it sticks.
        d.removeObject(forKey: "AppleLanguages")
        Brand.applyDefaultLanguage(d, bundleId: suite)
        check("System picked later: kept",
              d.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        d.removePersistentDomain(forName: suite)

        (d, suite) = fresh("picked")
        d.set(["fr"], forKey: "AppleLanguages")
        Brand.applyDefaultLanguage(d, bundleId: suite)
        check("language already picked: kept", d.stringArray(forKey: "AppleLanguages") == ["fr"])
        d.removePersistentDomain(forName: suite)

        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }
}
