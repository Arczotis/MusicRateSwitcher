import AppKit
import Foundation

public enum MusicPlayerID: String, CaseIterable, Codable, Sendable {
    case appleMusic
    case neteaseMusic
    case qqMusic
    case sodaMusic

    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .neteaseMusic: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .sodaMusic: return "汽水音乐"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .neteaseMusic: return "com.netease.163music"
        case .qqMusic: return "com.tencent.QQMusicMac"
        case .sodaMusic: return "com.soda.music"
        }
    }
}

public struct DetectedSourceFormat: Equatable, Sendable {
    public let player: MusicPlayerID
    public let format: SourceAudioFormat
    public let identifier: String?
    public let detectedAt: Date

    public init(
        player: MusicPlayerID,
        format: SourceAudioFormat,
        identifier: String? = nil,
        detectedAt: Date = Date()
    ) {
        self.player = player
        self.format = format
        self.identifier = identifier
        self.detectedAt = detectedAt
    }
}

public enum SampleRateSourceState: Equatable, Sendable {
    case appNotRunning
    case waitingForPlayback
    case detecting(String?)
    case playing(DetectedSourceFormat)
    /// macOS denied reading the player's data (App Data protection). The user
    /// has to grant access in System Settings; retrying will not help.
    case permissionRequired
    case error(String)
}

public enum FileAccess {
    /// True when the error means the sandbox / TCC refused the read, as opposed
    /// to a missing or malformed file.
    public static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }
}

public protocol SampleRateSource: AnyObject {
    var player: MusicPlayerID { get }
    var activityProcessIDs: [pid_t] { get }
    var onStateChanged: ((SampleRateSourceState) -> Void)? { get set }
    var onFormatChanged: ((DetectedSourceFormat) -> Void)? { get set }

    func start()
    func stop()
    func refreshNow()
}

public extension SampleRateSource {
    var activityProcessIDs: [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
    }
}
