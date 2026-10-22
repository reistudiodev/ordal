import Foundation

/// Copies preferences saved before the app was renamed to Ordal (theme,
/// diagram theme, editor split, diagram layouts). Runs once; never
/// overwrites a value Ordal already has.
enum LegacyDefaults {
    private static let doneKey = "migratedLegacyDefaults"
    /// Old preference domains: the `swift run` executable and the packaged app.
    private static let oldDomains = ["DBClientMac", "dev.dbclient.app"]
    private static let plainKeys = ["appTheme", "diagramTheme", "editorFraction"]
    private static let oldLayoutPrefix = "dbclient.diagram."
    private static let newLayoutPrefix = "ordal.diagram."

    static func migrateOnce(into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for domain in oldDomains {
            guard let old = UserDefaults.standard.persistentDomain(forName: domain) else { continue }
            for (key, value) in old {
                let newKey: String
                if plainKeys.contains(key) {
                    newKey = key
                } else if key.hasPrefix(oldLayoutPrefix) {
                    newKey = newLayoutPrefix + key.dropFirst(oldLayoutPrefix.count)
                } else {
                    continue
                }
                if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
