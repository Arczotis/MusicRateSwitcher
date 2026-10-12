import AppKit
import RateSwitcherCore

/// Commands the panel can send back to the app delegate.
protocol PanelActions: AnyObject {
    func setAutomatic(_ enabled: Bool)
    func setPlayer(_ player: MusicPlayerID, enabled: Bool)
    func openPlayer(_ player: MusicPlayerID)
    func selectDevice(uid: String?)
    func setMenuBarStyle(_ style: MenuBarStyle)
    func setLaunchAtLogin(_ enabled: Bool)
    func refreshNow()
    func openPrivacySettings()
    func openAudioMIDISetup()
    func showDiagnostics()
    func openLog()
    func copyDiagnostics()
    func showAbout()
    func quit()
}

enum PlayerPhase: Equatable {
    case disabled
    case notRunning
    case waiting
    case detecting
    case playing(SourceAudioFormat)
    case permissionRequired
    case error(String)
}

struct PlayerRowState: Identifiable, Equatable {
    let player: MusicPlayerID
    var phase: PlayerPhase
    var isEnabled: Bool
    var isInstalled: Bool
    var isActive: Bool

    var id: MusicPlayerID { player }
}

enum SyncState: Equatable {
    case idle
    case switching(Double)
    case matched(Double)
    case fallback(requested: Double, applied: Double)
    case failed(String)
}

/// Snapshot of everything the status item and popover render.
final class PanelModel: ObservableObject {
    @Published var players: [PlayerRowState] = MusicPlayerID.allCases.map {
        PlayerRowState(player: $0, phase: .notRunning, isEnabled: true, isInstalled: false, isActive: false)
    }
    @Published var activeDetection: DetectedSourceFormat?
    @Published var devices: [AudioOutputDevice] = []
    @Published var selectedDevice: AudioOutputDevice?
    @Published var followsSystemDefault = true
    @Published var autoSwitch = true
    @Published var launchAtLogin = false
    @Published var launchAtLoginAvailable = false
    @Published var menuBarStyle: MenuBarStyle = .compact
    @Published var sync: SyncState = .idle

    weak var actions: PanelActions?

    var version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

extension MusicPlayerID {
    var fallbackSymbol: String {
        switch self {
        case .appleMusic: return "music.note"
        case .neteaseMusic: return "waveform"
        case .qqMusic: return "music.note.list"
        case .sodaMusic: return "sparkles"
        }
    }

    /// Brand-ish tint used for the fallback glyph when the app is not installed.
    var tint: NSColor {
        switch self {
        case .appleMusic: return NSColor(srgbRed: 0.98, green: 0.24, blue: 0.33, alpha: 1)
        case .neteaseMusic: return NSColor(srgbRed: 0.87, green: 0.15, blue: 0.16, alpha: 1)
        case .qqMusic: return NSColor(srgbRed: 0.18, green: 0.75, blue: 0.47, alpha: 1)
        case .sodaMusic: return NSColor(srgbRed: 0.22, green: 0.47, blue: 0.98, alpha: 1)
        }
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var applicationIcon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        guard let url = applicationURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache[self] = icon
        return icon
    }

    private static var iconCache: [MusicPlayerID: NSImage] = [:]
}

extension SourceAudioFormat {
    /// "96" / "44.1" — the number without the unit, for large typography.
    static func rateNumber(_ rate: Double) -> String {
        let kHz = rate / 1_000
        if abs(kHz.rounded() - kHz) < 0.001 { return String(format: "%.0f", kHz) }
        return String(format: "%.1f", kHz)
    }

    var channelDescription: String? {
        switch channels {
        case nil: return nil
        case 1: return "单声道"
        case 2: return "立体声"
        case let count?: return "\(count) 声道"
        }
    }

    var qualityLabel: String {
        if sampleRate > 48_000.5 || (bitDepth ?? 16) > 16 { return "Hi-Res" }
        let lossy = ["MP3", "AAC", "OGG", "OPUS", "VORBIS"].contains { codec.uppercased().hasPrefix($0) }
        return lossy ? "标准" : "无损"
    }
}
