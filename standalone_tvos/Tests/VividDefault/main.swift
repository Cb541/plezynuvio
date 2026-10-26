import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let suite = "nuvio.vivid-default-tests.\(UUID().uuidString)"
guard let prefs = UserDefaults(suiteName: suite) else { fatalError("No test suite") }
defer { prefs.removePersistentDomain(forName: suite) }

require(NuvioVividPreferences.isEnabled(defaults: prefs),
        "Vivid should be ON for a fresh install")
NuvioVividPreferences.setEnabled(false, defaults: prefs)
require(!NuvioVividPreferences.isEnabled(defaults: prefs),
        "Manually turning Vivid OFF must persist")
require(!NuvioVividPreferences.isEnabled(defaults: UserDefaults(suiteName: suite)!),
        "Vivid OFF must remain across new player instances")
NuvioVividPreferences.setEnabled(true, defaults: prefs)
require(NuvioVividPreferences.isEnabled(defaults: UserDefaults(suiteName: suite)!),
        "Turning Vivid ON must persist across relaunches")
print("Vivid default-ON and persisted manual choice: PASS")
