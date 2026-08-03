import AppKit
import Darwin
import Foundation

public final class NeteasePlaybackMonitor: SampleRateSource {
    public static let bundleIdentifier = MusicPlayerID.neteaseMusic.bundleIdentifier
    public let player = MusicPlayerID.neteaseMusic

    public var onStateChanged: ((SampleRateSourceState) -> Void)?
    public var onFormatChanged: ((DetectedSourceFormat) -> Void)?

    private struct OpenAudioFile {
        let url: URL
        let offset: Int64
        let size: Int64
        let openFlags: UInt32
    }

    private let queue = DispatchQueue(label: "io.github.music-rate-switcher.netease-monitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var pid: pid_t?
    private var previousOffsets: [URL: Int64] = [:]
    private var activeURL: URL?
    private var lastFormat: SourceAudioFormat?
    private var lastState: SampleRateSourceState?
    private var parseFailures: [URL: Int] = [:]

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
            Diagnostics.shared.info("网易云播放监视器已启动")
        }
    }

    public func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            previousOffsets.removeAll()
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
            previousOffsets.removeAll()
            parseFailures.removeAll()
            Diagnostics.shared.info("检测到网易云音乐进程 PID=\(runningPID)")
        }

        let files = enumerateOpenAudioFiles(pid: runningPID)
        guard !files.isEmpty else {
            activeURL = nil
            lastFormat = nil
            emit(.waitingForPlayback)
            return
        }

        guard let selected = selectActiveFile(from: files, force: force) else {
            emit(.waitingForPlayback)
            return
        }
        let changedFile = selected.url != activeURL
        if changedFile {
            activeURL = selected.url
            lastFormat = nil
            emit(.detecting(selected.url.lastPathComponent))
            Diagnostics.shared.info("检测当前播放文件：\(selected.url.lastPathComponent)")
        }

        guard changedFile || force || lastFormat == nil else { return }
        do {
            let format = try parseFormat(at: selected.url)
            parseFailures[selected.url] = nil
            let detection = DetectedSourceFormat(
                player: player,
                format: format,
                identifier: selected.url.path
            )
            emit(.playing(detection))
            if format != lastFormat || changedFile {
                lastFormat = format
                Diagnostics.shared.info("源格式：\(format.description)")
                DispatchQueue.main.async { self.onFormatChanged?(detection) }
            }
        } catch AudioFormatParseError.insufficientData {
            scheduleRetry(for: selected.url, message: "缓存头尚未写入完整")
        } catch {
            scheduleRetry(for: selected.url, message: error.localizedDescription)
        }
    }

    private func currentPID() -> pid_t? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        return apps.first(where: { !$0.isTerminated })?.processIdentifier
    }

    private func enumerateOpenAudioFiles(pid: pid_t) -> [OpenAudioFile] {
        let estimatedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimatedBytes > 0 else { return [] }

        let itemSize = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(proc_fd: 0, proc_fdtype: 0),
            count: Int(estimatedBytes) / itemSize + 32
        )
        let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard actualBytes > 0 else { return [] }

        var results: [OpenAudioFile] = []
        for descriptor in descriptors.prefix(Int(actualBytes) / itemSize) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = MemoryLayout<vnode_fdinfowithpath>.stride
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, $0, Int32(size))
            }
            guard read == size else { continue }
            let path: String = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard isSupportedPlaybackPath(path) else { continue }
            let url = URL(fileURLWithPath: path)
            let statSize = info.pvip.vip_vi.vi_stat.vst_size
            results.append(OpenAudioFile(
                url: url,
                offset: info.pfi.fi_offset,
                size: statSize,
                openFlags: info.pfi.fi_openflags
            ))
        }
        return results
    }

    private func isSupportedPlaybackPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/online_play_cache/") && lower.hasSuffix(".uc!") { return true }
        let supported = [".flac", ".mp3", ".m4a", ".mp4", ".aac", ".wav", ".aif", ".aiff"]
        return supported.contains(where: lower.hasSuffix)
    }

    private func selectActiveFile(from files: [OpenAudioFile], force: Bool) -> OpenAudioFile? {
        let readable = files.filter { Int32($0.openFlags) & O_ACCMODE != O_WRONLY }
        let candidates = readable.isEmpty ? files : readable
        defer { previousOffsets = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url, $0.offset) }) }
        if candidates.count == 1 { return candidates[0] }

        let moving = candidates.compactMap { file -> (OpenAudioFile, Int64)? in
            guard let old = previousOffsets[file.url] else { return nil }
            let delta = file.offset - old
            return delta > 0 ? (file, delta) : nil
        }
        if let mostActive = moving.max(by: { $0.1 < $1.1 })?.0 { return mostActive }
        if let activeURL, let existing = candidates.first(where: { $0.url == activeURL }) { return existing }
        if force {
            return candidates.max(by: { modificationDate($0.url) < modificationDate($1.url) })
        }
        return candidates.max(by: { $0.offset < $1.offset })
    }

    private func parseFormat(at url: URL) throws -> SourceAudioFormat {
        if url.pathExtension.lowercased() == "uc!" {
            return try NeteaseCacheDecoder.readFormat(at: url)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
        return try EncodedAudioParser.parse(data)
    }

    private func scheduleRetry(for url: URL, message: String) {
        let failures = (parseFailures[url] ?? 0) + 1
        parseFailures[url] = failures
        if failures <= 8 {
            if failures == 1 { Diagnostics.shared.info("等待解析 \(url.lastPathComponent)：\(message)") }
            queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.poll(force: true) }
        } else {
            let text = "无法解析当前音频：\(message)"
            Diagnostics.shared.warning(text)
            emit(.error(text))
        }
    }

    private func resetForMissingApp() {
        if pid != nil { Diagnostics.shared.info("网易云音乐已退出") }
        pid = nil
        activeURL = nil
        lastFormat = nil
        previousOffsets.removeAll()
        parseFailures.removeAll()
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func emit(_ state: SampleRateSourceState) {
        guard state != lastState else { return }
        lastState = state
        DispatchQueue.main.async { self.onStateChanged?(state) }
    }
}
