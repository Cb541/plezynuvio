import Foundation

/// Global Vivid preference shared by every video and future app launches.
/// The first-run default is ON; an explicit OFF choice is respected. The
/// video controller still excludes native Dolby Vision and requires an
/// explicit per-video HDR Boost opt-in before applying a software filter.
enum NuvioVividPreferences {
    static let key = "Nuvio.VividEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
