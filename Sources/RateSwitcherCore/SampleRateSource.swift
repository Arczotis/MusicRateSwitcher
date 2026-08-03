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
    case error(String)
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
