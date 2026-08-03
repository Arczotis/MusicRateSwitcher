import Foundation
import RateSwitcherCore

final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let autoSwitch = "autoSwitch"
        static let selectedDeviceUID = "selectedDeviceUID"
        static let showRateInMenuBar = "showRateInMenuBar"
        static let appleMusicEnabled = "appleMusicEnabled"
        static let neteaseMusicEnabled = "neteaseMusicEnabled"
        static let qqMusicEnabled = "qqMusicEnabled"
        static let sodaMusicEnabled = "sodaMusicEnabled"
        static let hasShownWelcome = "hasShownWelcome"
        static let didMigrateLegacyDefaults = "didMigrateLegacyDefaults"
    }

    private let defaults = UserDefaults.standard

    private init() {
        migrateLegacyDefaultsIfNeeded()
        defaults.register(defaults: [
            Key.autoSwitch: true,
            Key.showRateInMenuBar: true,
            Key.appleMusicEnabled: true,
            Key.neteaseMusicEnabled: true,
            Key.qqMusicEnabled: true,
            Key.sodaMusicEnabled: true
        ])
    }

    var autoSwitch: Bool {
        get { defaults.bool(forKey: Key.autoSwitch) }
        set { defaults.set(newValue, forKey: Key.autoSwitch) }
    }

    var selectedDeviceUID: String? {
        get { defaults.string(forKey: Key.selectedDeviceUID) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.selectedDeviceUID) }
            else { defaults.removeObject(forKey: Key.selectedDeviceUID) }
        }
    }

    var showRateInMenuBar: Bool {
        get { defaults.bool(forKey: Key.showRateInMenuBar) }
        set { defaults.set(newValue, forKey: Key.showRateInMenuBar) }
    }

    var hasShownWelcome: Bool {
        get { defaults.bool(forKey: Key.hasShownWelcome) }
        set { defaults.set(newValue, forKey: Key.hasShownWelcome) }
    }

    func isSourceEnabled(_ player: MusicPlayerID) -> Bool {
        switch player {
        case .appleMusic: return defaults.bool(forKey: Key.appleMusicEnabled)
        case .neteaseMusic: return defaults.bool(forKey: Key.neteaseMusicEnabled)
        case .qqMusic: return defaults.bool(forKey: Key.qqMusicEnabled)
        case .sodaMusic: return defaults.bool(forKey: Key.sodaMusicEnabled)
        }
    }

    func setSourceEnabled(_ enabled: Bool, player: MusicPlayerID) {
        switch player {
        case .appleMusic: defaults.set(enabled, forKey: Key.appleMusicEnabled)
        case .neteaseMusic: defaults.set(enabled, forKey: Key.neteaseMusicEnabled)
        case .qqMusic: defaults.set(enabled, forKey: Key.qqMusicEnabled)
        case .sodaMusic: defaults.set(enabled, forKey: Key.sodaMusicEnabled)
        }
    }

    private func migrateLegacyDefaultsIfNeeded() {
        guard defaults.object(forKey: Key.didMigrateLegacyDefaults) == nil else { return }
        if let old = UserDefaults(suiteName: "io.github.netease-rate-switcher") {
            for key in [Key.autoSwitch, Key.selectedDeviceUID, Key.showRateInMenuBar] {
                if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: Key.didMigrateLegacyDefaults)
    }
}
