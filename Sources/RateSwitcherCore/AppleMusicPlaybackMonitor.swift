import AppKit
import Foundation

public final class AppleMusicPlaybackMonitor: SampleRateSource {
    public static let bundleIdentifier = MusicPlayerID.appleMusic.bundleIdentifier
    public let player = MusicPlayerID.appleMusic

    public var onStateChanged: ((SampleRateSourceState) -> Void)?
    public var onFormatChanged: ((DetectedSourceFormat) -> Void)?

    private static let predicate = #"process == "Music" AND (category == "ampplay" OR subsystem == "com.apple.coreaudio")"#

    private let queue = DispatchQueue(label: "io.github.music-rate-switcher.apple-music", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var logProcess: Process?
    private var streamBuffer = Data()
    private var runningPID: pid_t?
    private var lastState: SampleRateSourceState?
    private var lastDetection: DetectedSourceFormat?
    private var playbackGeneration = 0
    private var intentionallyStopping = false

    public init() {}

    deinit { stop() }

    public func start() {
        queue.async {
            guard self.timer == nil else { return }
            self.intentionallyStopping = false
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.checkApplicationState() }
            self.timer = timer
            timer.resume()
            self.checkApplicationState()
            Diagnostics.shared.info("Apple Music 日志监视器已启动")
        }
    }

    public func stop() {
        queue.sync {
            intentionallyStopping = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            stopLogProcess()
            runningPID = nil
            streamBuffer.removeAll(keepingCapacity: false)
        }
    }

    public func refreshNow() {
        queue.async {
            self.stopLogProcess()
            self.checkApplicationState(forceRecentLookup: true)
        }
    }

    private func checkApplicationState(forceRecentLookup: Bool = false) {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first(where: { !$0.isTerminated })
        guard let app else {
            if runningPID != nil { Diagnostics.shared.info("Apple Music 已退出") }
            runningPID = nil
            lastDetection = nil
            stopLogProcess()
            emit(.appNotRunning)
            return
        }

        let changedProcess = runningPID != app.processIdentifier
        if changedProcess {
            runningPID = app.processIdentifier
            lastDetection = nil
            playbackGeneration += 1
            Diagnostics.shared.info("检测到 Apple Music 进程 PID=\(app.processIdentifier)")
        }
        if logProcess == nil { spawnLogStream() }
        if changedProcess || forceRecentLookup { readRecentLogs() }
        if lastDetection == nil { emit(.waitingForPlayback) }
    }

    private func spawnLogStream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "debug", "--style", "ndjson", "--no-backtrace",
            "--predicate", Self.predicate
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Diagnostics.shared.warning("Apple Music 日志进程：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.queue.async {
                guard let self, self.logProcess === terminated else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.logProcess = nil
                if !self.intentionallyStopping, self.runningPID != nil {
                    Diagnostics.shared.warning("Apple Music 日志进程退出，准备重启")
                    self.queue.asyncAfter(deadline: .now() + 1) { self.checkApplicationState() }
                }
            }
        }
        do {
            try process.run()
            logProcess = process
            Diagnostics.shared.info("Apple Music 实时日志流已连接")
        } catch {
            Diagnostics.shared.error("无法启动 Apple Music 日志流：\(error.localizedDescription)")
            emit(.error("无法读取 Apple Music 日志"))
        }
    }

    private func stopLogProcess() {
        guard let process = logProcess else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        logProcess = nil
        streamBuffer.removeAll(keepingCapacity: false)
    }

    private func readRecentLogs() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show", "--last", "5m", "--info", "--debug", "--style", "ndjson",
                "--predicate", Self.predicate
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                self?.queue.async { self?.consumeRecent(data) }
            } catch {
                Diagnostics.shared.warning("无法读取 Apple Music 近期日志：\(error.localizedDescription)")
            }
        }
    }

    private func consume(_ data: Data) {
        streamBuffer.append(data)
        while let newline = streamBuffer.firstIndex(of: 0x0a) {
            let line = streamBuffer.prefix(upTo: newline)
            streamBuffer.removeSubrange(...newline)
            processJSONLine(Data(line))
        }
    }

    private func consumeRecent(_ data: Data) {
        let lines = data.split(separator: 0x0a)
        var observations: [AppleMusicLogObservation] = []
        for line in lines {
            if let message = eventMessage(from: Data(line)), let observation = AppleMusicLogParser.parse(message: message) {
                observations.append(observation)
            }
        }
        if let active = observations.last(where: { $0.confidence == .activePlayback }) {
            accept(active)
        } else if let fallback = observations.last {
            accept(fallback)
        }
    }

    private func processJSONLine(_ data: Data) {
        guard let message = eventMessage(from: data), let observation = AppleMusicLogParser.parse(message: message) else { return }
        if observation.confidence == .activePlayback {
            playbackGeneration += 1
            accept(observation)
        } else {
            let generation = playbackGeneration
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, generation == self.playbackGeneration else { return }
                self.accept(observation)
            }
        }
    }

    private func eventMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["eventMessage"] as? String
            ?? object["message"] as? String
            ?? object["composedMessage"] as? String
    }

    private func accept(_ observation: AppleMusicLogObservation) {
        let detection = DetectedSourceFormat(
            player: player,
            format: observation.format,
            identifier: observation.trackIdentifier
        )
        if let lastDetection,
           lastDetection.format == detection.format,
           lastDetection.identifier == detection.identifier,
           detection.detectedAt.timeIntervalSince(lastDetection.detectedAt) < 2 {
            return
        }
        lastDetection = detection
        Diagnostics.shared.info("Apple Music 源格式：\(detection.format.description)")
        emit(.playing(detection))
        DispatchQueue.main.async { self.onFormatChanged?(detection) }
    }

    private func emit(_ state: SampleRateSourceState) {
        guard state != lastState else { return }
        lastState = state
        DispatchQueue.main.async { self.onStateChanged?(state) }
    }
}
