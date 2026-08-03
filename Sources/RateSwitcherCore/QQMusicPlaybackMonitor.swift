import AppKit
import CSQLite
import Foundation

public struct QQMusicSongMetadata: Equatable, Sendable {
    public let title: String?
    public let sampleRate: Double?
    public let bitDepth: Int?

    public init(title: String?, sampleRate: Double?, bitDepth: Int?) {
        self.title = title
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }
}

public enum QQMusicSongMetadataParser {
    public static func parse(_ data: Data) -> QQMusicSongMetadata? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let songs = root["data"] as? [[String: Any]],
            let song = songs.first,
            let file = song["file"] as? [String: Any]
        else { return nil }

        let rawRate = number(file["hires_sample"])
        let normalizedRate: Double?
        if let rawRate, rawRate > 0 {
            normalizedRate = rawRate < 1_000 ? rawRate * 1_000 : rawRate
        } else {
            normalizedRate = nil
        }
        let rawDepth = number(file["hires_bitdepth"])
        let bitDepth = rawDepth.flatMap { $0 > 0 ? Int($0) : nil }
        return QQMusicSongMetadata(
            title: song["title"] as? String ?? song["name"] as? String,
            sampleRate: normalizedRate,
            bitDepth: bitDepth
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public final class QQMusicPlaybackMonitor: SampleRateSource {
    public static let bundleIdentifier = MusicPlayerID.qqMusic.bundleIdentifier
    public let player = MusicPlayerID.qqMusic

    public var onStateChanged: ((SampleRateSourceState) -> Void)?
    public var onFormatChanged: ((DetectedSourceFormat) -> Void)?

    private let queue = DispatchQueue(label: "io.github.music-rate-switcher.qq-music", qos: .userInitiated)
    private let cacheDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iRRCache/rrdbcache.sqlite")
    private var timer: DispatchSourceTimer?
    private var pid: pid_t?
    private var activeURL: URL?
    private var lastFormat: SourceAudioFormat?
    private var lastState: SampleRateSourceState?
    private var metadataCache: [String: QQMusicSongMetadata] = [:]
    private var metadataFailures: Set<String> = []
    private var pendingSongID: String?

    public init() {}

    deinit { stop() }

    public func start() { startPolling(interval: 0.8) }

    public func startPolling(interval: TimeInterval) {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(120))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
            self.poll(force: true)
            Diagnostics.shared.info("QQ 音乐播放监视器已启动")
        }
    }

    public func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            activeURL = nil
            pendingSongID = nil
        }
    }

    public func refreshNow() { queue.async { self.poll(force: true) } }

    private func poll(force: Bool = false) {
        guard let runningPID = currentPID() else {
            resetForMissingApp()
            emit(.appNotRunning)
            return
        }
        if runningPID != pid {
            pid = runningPID
            activeURL = nil
            lastFormat = nil
            pendingSongID = nil
            Diagnostics.shared.info("检测到 QQ 音乐进程 PID=\(runningPID)")
        }

        guard let url = mostRecentlyAccessedAudioURL() else {
            emit(.waitingForPlayback)
            return
        }
        let changedFile = url != activeURL
        if changedFile {
            activeURL = url
            lastFormat = nil
            pendingSongID = nil
            emit(.detecting(url.lastPathComponent))
            Diagnostics.shared.info("QQ 音乐当前缓存：\(url.lastPathComponent)")
        }
        guard changedFile || force || lastFormat == nil else { return }

        let fileExtension = url.pathExtension.lowercased()
        if !Self.encryptedExtensions.contains(fileExtension) {
            do {
                let format = try readFormat(at: url)
                accept(format, url: url, identifier: url.path)
                return
            } catch {
                Diagnostics.shared.warning("QQ 音乐本地音频头解析失败：\(error.localizedDescription)")
            }
        }

        guard let songID = Self.songID(from: url) else {
            accept(fallbackFormat(for: fileExtension), url: url, identifier: url.path)
            return
        }
        if let cached = metadataCache[songID] {
            accept(format(from: cached, extension: fileExtension), url: url, identifier: "QQ songid=\(songID)")
        } else if metadataFailures.contains(songID) {
            accept(fallbackFormat(for: fileExtension), url: url, identifier: "QQ songid=\(songID)")
        } else if pendingSongID != songID {
            pendingSongID = songID
            requestMetadata(songID: songID, url: url, fileExtension: fileExtension)
        }
    }

    private func currentPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    private func mostRecentlyAccessedAudioURL() -> URL? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(cacheDatabaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database
        else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT data FROM Cache WHERE type = 2 ORDER BY accessTime DESC LIMIT 12"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: count)
            guard let path = Self.unarchivePath(data), Self.isAudioPath(path) else { continue }
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func unarchivePath(_ data: Data) -> String? {
        (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data)) as String?
    }

    private static let encryptedExtensions: Set<String> = ["mgg", "mflac", "qmc0", "qmc3", "qmcflac", "tm0", "tm3"]
    private static let audioExtensions: Set<String> = encryptedExtensions.union([
        "flac", "mp3", "m4a", "mp4", "aac", "wav", "wave", "aif", "aiff", "ogg"
    ])

    private static func isAudioPath(_ path: String) -> Bool {
        audioExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public static func songID(from url: URL) -> String? {
        let prefix = url.deletingPathExtension().lastPathComponent.split(separator: "-").first.map(String.init)
        guard let prefix, !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return prefix
    }

    private func readFormat(at url: URL) throws -> SourceAudioFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
        return try EncodedAudioParser.parse(data)
    }

    private func requestMetadata(songID: String, url: URL, fileExtension: String) {
        var components = URLComponents(string: "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg")
        components?.queryItems = [
            URLQueryItem(name: "songid", value: songID),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let endpoint = components?.url else {
            metadataFailures.insert(songID)
            pendingSongID = nil
            accept(fallbackFormat(for: fileExtension), url: url, identifier: "QQ songid=\(songID)")
            return
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 5)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            let metadata = data.flatMap(QQMusicSongMetadataParser.parse)
            self.queue.async {
                self.pendingSongID = nil
                if let metadata { self.metadataCache[songID] = metadata }
                else { self.metadataFailures.insert(songID) }
                guard self.activeURL == url else { return }
                if let error { Diagnostics.shared.warning("QQ 音乐元数据请求失败：\(error.localizedDescription)") }
                let format = self.format(from: metadata, extension: fileExtension)
                self.accept(format, url: url, identifier: "QQ songid=\(songID)")
            }
        }.resume()
    }

    private func format(from metadata: QQMusicSongMetadata?, extension fileExtension: String) -> SourceAudioFormat {
        guard let sampleRate = metadata?.sampleRate else { return fallbackFormat(for: fileExtension) }
        return SourceAudioFormat(
            sampleRate: sampleRate,
            bitDepth: metadata?.bitDepth,
            channels: 2,
            codec: "Hi-Res (QQ)"
        )
    }

    private func fallbackFormat(for fileExtension: String) -> SourceAudioFormat {
        let codec: String
        switch fileExtension {
        case "mflac", "qmcflac": codec = "FLAC (QQ)"
        case "mgg": codec = "Ogg (QQ)"
        default: codec = "QQ Music"
        }
        return SourceAudioFormat(sampleRate: 44_100, bitDepth: 16, channels: 2, codec: codec)
    }

    private func accept(_ format: SourceAudioFormat, url: URL, identifier: String) {
        guard activeURL == url else { return }
        let detection = DetectedSourceFormat(player: player, format: format, identifier: identifier)
        emit(.playing(detection))
        if format != lastFormat {
            lastFormat = format
            Diagnostics.shared.info("QQ 音乐源格式：\(format.description)")
            DispatchQueue.main.async { self.onFormatChanged?(detection) }
        }
    }

    private func resetForMissingApp() {
        if pid != nil { Diagnostics.shared.info("QQ 音乐已退出") }
        pid = nil
        activeURL = nil
        lastFormat = nil
        pendingSongID = nil
    }

    private func emit(_ state: SampleRateSourceState) {
        guard state != lastState else { return }
        lastState = state
        DispatchQueue.main.async { self.onStateChanged?(state) }
    }
}
