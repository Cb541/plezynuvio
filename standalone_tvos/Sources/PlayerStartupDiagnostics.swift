import Foundation

/// Minimal crash breadcrumb. No video addresses, tokens or viewing history
/// are retained. The phase is removed after playback starts or exits cleanly.
/// A phase left on the next app launch indicates interrupted startup, not
/// necessarily an application exception (tvOS might have terminated the app).
enum PlayerStartupDiagnostics {
    private static let phaseKey = "NuvioNative.UnfinishedPlaybackStartupPhase"
    static var unfinishedPhase: String? {
        UserDefaults.standard.string(forKey: phaseKey)
    }

    static func mark(_ phase: String) {
        UserDefaults.standard.set(phase, forKey: phaseKey)
        UserDefaults.standard.synchronize()
        NSLog("[NuvioNative] Startup stage: %@", phase)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: phaseKey)
        UserDefaults.standard.synchronize()
    }
}
