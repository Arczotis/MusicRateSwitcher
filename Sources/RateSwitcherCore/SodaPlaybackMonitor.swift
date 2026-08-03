import AppKit
import Darwin
import Foundation

public final class SodaPlaybackMonitor: SampleRateSource {
    public static let bundleIdentifier = MusicPlayerID.sodaMusic.bundleIdentifier
    public let player = MusicPlayerID.sodaMusic

    public var onStateChanged: ((SampleRateSourceState) -> Void)?
    public var onFormatChanged: ((DetectedSourceFormat) -> Void)?

    public var activityProcessIDs: [pid_t] {
        guard let root = currentPID() else { return [] }
        var result = [root]
        var pending = [root]
        var seen: Set<pid_t> = [root]
        while let parent = pending.popLast() {
            for child in Self.directChildren(of: parent) where seen.insert(child).inserted {
                result.append(child)
                pending.append(child)
            }
        }
        return result
    }

    private struct CacheFile {
        let url: URL
        let modifiedAt: Date
        let size: Int
    }

    private let queue = DispatchQueue(label: "io.github.music-rate-switcher.soda-music", qos: .userInitiated)
    private let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.soda.music/Data/Library/Application Support/SodaMusic/LunaCacheV2", isDirectory: true)
    private var timer: DispatchSourceTimer?
    private var pid: pid_t?
    private var activeURL: URL?
    private var lastFormat: SourceAudioFormat?
    private var lastState: SampleRateSourceState?
    private var parseFailures: [URL: Int] = [:]

    public init() {}

    deinit { stop() }

    public func start() { startPolling(interval: 0.65) }

    public func startPolling(interval: TimeInterval) {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
            self.poll(force: true)
            Diagnostics.shared.info("汽水音乐播放监视器已启动")
        }
    }

    public func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            activeURL = nil
            parseFailures.removeAll()
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
            parseFailures.removeAll()
            Diagnostics.shared.info("检测到汽水音乐进程 PID=\(runningPID)")
        }

        guard let selected = selectCurrentCacheFile() else {
            emit(.waitingForPlayback)
            return
        }
        let changedFile = selected.url != activeURL
        if changedFile {
            activeURL = selected.url
            lastFormat = nil
            emit(.detecting(selected.url.lastPathComponent))
            Diagnostics.shared.info("汽水音乐当前缓存：\(selected.url.lastPathComponent)")
        }
        guard changedFile || force || lastFormat == nil else { return }

        do {
            let format = try readFormat(at: selected.url)
            parseFailures[selected.url] = nil
            let detection = DetectedSourceFormat(player: player, format: format, identifier: selected.url.path)
            emit(.playing(detection))
            if format != lastFormat || changedFile {
                lastFormat = format
                Diagnostics.shared.info("汽水音乐源格式：\(format.description)")
                DispatchQueue.main.async { self.onFormatChanged?(detection) }
            }
        } catch {
            let failures = (parseFailures[selected.url] ?? 0) + 1
            parseFailures[selected.url] = failures
            if failures == 1 {
                Diagnostics.shared.info("等待汽水音乐缓存头写入完整：\(error.localizedDescription)")
            } else if failures == 12 {
                Diagnostics.shared.warning("暂时无法解析汽水音乐缓存：\(error.localizedDescription)")
            }
        }
    }

    private func currentPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    private func selectCurrentCacheFile() -> CacheFile? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let files = urls.compactMap { url -> CacheFile? in
            guard url.pathExtension.lowercased() == "bin",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  let size = values.fileSize,
                  size > 0
            else { return nil }
            return CacheFile(url: url, modifiedAt: modifiedAt, size: size)
        }
        guard let newestDate = files.map(\.modifiedAt).max() else { return nil }

        // 汽水会先创建当前曲目，再在数秒内预载后续曲目。取最新批次中最早创建/写完的文件。
        let newestBatch = files.filter { newestDate.timeIntervalSince($0.modifiedAt) <= 15 }
        return newestBatch.min {
            if $0.modifiedAt == $1.modifiedAt { return $0.size > $1.size }
            return $0.modifiedAt < $1.modifiedAt
        }
    }

    private func readFormat(at url: URL) throws -> SourceAudioFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
        return try EncodedAudioParser.parse(data)
    }

    private static func directChildren(of parent: pid_t) -> [pid_t] {
        let capacity = proc_listchildpids(parent, nil, 0)
        guard capacity > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(capacity))
        let count = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(children.prefix(Int(count))).filter { $0 > 0 }
    }

    private func resetForMissingApp() {
        if pid != nil { Diagnostics.shared.info("汽水音乐已退出") }
        pid = nil
        activeURL = nil
        lastFormat = nil
        parseFailures.removeAll()
    }

    private func emit(_ state: SampleRateSourceState) {
        guard state != lastState else { return }
        lastState = state
        DispatchQueue.main.async { self.onStateChanged?(state) }
    }
}
