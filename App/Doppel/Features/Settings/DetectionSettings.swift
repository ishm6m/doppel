import DetectionEngine
import DoppelKit
import Foundation

/// The persisted user settings that shape a scan (F11). Stored in `UserDefaults.standard` — the same
/// store `@AppStorage` writes to — so the Settings UI and the scan read one source of truth. Keep the
/// keys here and reference them from both `SettingsView` (binding) and the scan (reading).
enum SettingsKey {
    static let nearDupThreshold = "detection.nearDupThreshold"
    static let ocrEnabled = "detection.ocrEnabled"
    static let scanImages = "detection.scanImages" // V2 — off, surfaced disabled in the UI
}

/// Reads the persisted settings and turns them into the engine inputs for the next scan, so a change
/// in Settings takes effect on the following scan with no extra wiring.
enum DetectionSettings {
    /// Registers defaults so the first read (before the user opens Settings) matches `DetectionConfig`'s
    /// own defaults. Call once at launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.nearDupThreshold: DetectionConfig().nearDupTextThreshold,
            SettingsKey.ocrEnabled: false,
            SettingsKey.scanImages: false
        ])
    }

    /// File-type scopes to scan. Documents always; images only when the (V2) toggle is on.
    static var scopes: Set<FileTypeScope> {
        var scopes: Set<FileTypeScope> = [.document]
        if UserDefaults.standard.bool(forKey: SettingsKey.scanImages) { scopes.insert(.image) }
        return scopes
    }

    /// Engine config built from the persisted thresholds/toggles (defaults fill anything unset).
    static var config: DetectionConfig {
        var config = DetectionConfig()
        let threshold = UserDefaults.standard.double(forKey: SettingsKey.nearDupThreshold)
        if threshold > 0 { config.nearDupTextThreshold = threshold }
        config.ocrEnabled = UserDefaults.standard.bool(forKey: SettingsKey.ocrEnabled)
        return config
    }
}
